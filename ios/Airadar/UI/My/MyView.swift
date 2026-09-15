import SwiftUI
import MapKit

/// Full-screen map of every leg flown — bowed arcs only, never the raw jagged
/// ADS-B trail, coloured by direction (blue north, green south) rather than by
/// trip — with the stats panel at the bottom and Settings at the top right. Tap
/// a line for the flights on that route, oldest to newest; tap an airport's dot
/// for that airport itself — terminals, how far it is, a way to navigate there.
struct MyView: View {
    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var settings: SettingsModel

    /// The cards on offer below the map, and which one is on screen — swiping
    /// changes the page, and the page in turn decides the one line lit up above.
    @State private var browsing: [Flight] = []
    @State private var currentFlightId: String?
    /// The airport whose dot was tapped — its own info sheet, not a leg carousel.
    @State private var airportInfo: Airport?
    @State private var openId: String?
    @State private var showSettings = false
    @State private var homeRegion: Region?
    @State private var trackStatus: [String: TrackStatus] = [:]
    /// Among today's departures, which ones driving can actually reach — those
    /// dots draw blue and skip straight to Maps instead of opening the sheet.
    @State private var reachableSoon: Set<String> = []

    /// Flown legs, and the one in the air right now with the plane on it.
    private var history: [Flight] { store.flights.filter { ($0.phase == .past || $0.phase == .inProgress) && !$0.isPending } }
    /// Every leg as a bowed arc — never the real recorded track, which kinks and
    /// looks jagged at the zoomed-out scale this overview is seen at. The one in
    /// the air still gets its dashed-ahead / solid-flown split, timed by the clock.
    private var routes: [MapRoute] { history.toMapRoutes() }
    /// Departure airports for anything leaving within a day — shown even with no
    /// arc into them yet, so there is a dot there at all to turn blue.
    private var upcomingDepartures: [Airport] {
        let soon = store.flights.filter {
            $0.phase == .upcoming && ($0.departureInstant ?? .distantFuture).timeIntervalSinceNow <= 86400
        }
        var seen: Set<String> = []
        return soon.compactMap { $0.departureAirport }.filter { seen.insert($0.iata).inserted }
    }
    private var highlightedAirports: [TileMapView.HighlightedAirport] {
        upcomingDepartures.map { .init(airport: $0, reachable: reachableSoon.contains($0.iata)) }
    }

    /// Just the current card's own line — never more than one, whichever page
    /// you've swiped to.
    private var highlighted: (Airport, Airport, Int)? {
        guard let id = currentFlightId, let f = browsing.first(where: { $0.id == id }),
              let a = f.departureAirport, let b = f.arrivalAirport else { return nil }
        return (a, b, rankOf(f, from: a, to: b))
    }

    /// Where a flight sits among its own repeats, oldest first — the same order
    /// `toMapRoutes()` ranked it in when it bowed the arc.
    private func rankOf(_ flight: Flight, from a: Airport, to b: Airport) -> Int {
        history.filter { $0.departure == a.iata && $0.arrival == b.iata }
            .sorted { ($0.departureInstant ?? .distantPast) < ($1.departureInstant ?? .distantPast) }
            .firstIndex { $0.id == flight.id } ?? 0
    }

    /// One line tapped: every flight this exact route has ever had, oldest to
    /// newest, opened on the one tapped — swipe left for earlier, right for later.
    private func legTapped(_ a: Airport, _ b: Airport, _ rank: Int) {
        let onRoute = history.filter { $0.departure == a.iata && $0.arrival == b.iata }
            .sorted { ($0.departureInstant ?? .distantPast) < ($1.departureInstant ?? .distantPast) }
        browsing = onRoute
        currentFlightId = (onRoute.indices.contains(rank) ? onRoute[rank] : onRoute.last)?.id
    }

    /// A blue dot (leaving within a day, and reachable) jumps straight into
    /// driving directions; any other dot opens the airport's own info sheet.
    /// Blue or not, a tap opens the same info sheet — blue only says a trip
    /// leaves from here soon and driving there is possible; jumping straight
    /// into Maps with no way to see the airport's own details first (which
    /// terminal, how long) wasn't actually useful once it was in front of you.
    private func airportTapped(_ a: Airport) { airportInfo = a }

    /// Checked once per set of near departures — not on every redraw — since
    /// each is a real network round trip to Apple's routing service.
    private func checkReachability() async {
        guard let origin = await HomeRegion.coarseCoordinate() else { reachableSoon = []; return }
        var found: Set<String> = []
        for airport in upcomingDepartures {
            if await DirectionsETA.seconds(from: origin, to: airport.coordinate, by: .automobile) != nil {
                found.insert(airport.iata)
            }
        }
        reachableSoon = found
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Full-bleed, as it was — direction tells the colour: blue heading
                // north, green heading south, so the web of past legs reads at a glance.
                TileMapView(routes: routes, interactive: true, directionColored: true, selected: highlighted,
                            highlightedAirports: highlightedAirports, emptyFocus: homeRegion,
                            onLegTap: legTapped, onAirportTap: airportTapped, onMapTap: { browsing = []; currentFlightId = nil })
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    if !browsing.isEmpty {
                        // Same width as the stats panel; swiping pages through the flights
                        // on this route and re-lights the matching arc as you go.
                        TabView(selection: $currentFlightId) {
                            ForEach(browsing) { f in
                                LegCard(flight: f) { openId = f.id }
                                    .padding(.horizontal, 12)
                                    .tag(f.id as String?)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 118)
                    }
                    StatsPanel(stats: history.travelStats())
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 12)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
            // With no trips yet the map looks at where the traveller is.
            .task(id: history.isEmpty) {
                if history.isEmpty { homeRegion = await HomeRegion.find() }
            }
            .task(id: upcomingDepartures.map(\.iata)) { await checkReachability() }
        }
        .sheet(item: $openId) { id in
            if let f = store.flights.first(where: { $0.id == id }) {
                FlightDetailSheet(flight: f, forceSystemZone: settings.forceSystemZone, trackStatus: trackStatus[f.id],
                                  onLoadTrack: { load(f) }, onDismiss: { openId = nil })
            }
        }
        .sheet(item: $airportInfo) { a in
            AirportInfoSheet(airport: a, history: history)
                .presentationDetents([.medium])
        }
    }

    private func load(_ f: Flight) {
        trackStatus[f.id] = .loading
        Task {
            do {
                let t = try await OpenSkyClient.shared.fetchTrack(f)
                store.setTrack(f.id, points: t.points, flownOn: t.flownOn, icao24: t.icao24)
                trackStatus[f.id] = .loaded
            } catch { trackStatus[f.id] = .failed(error.localizedDescription) }
        }
    }
}

private struct LegCard: View {
    let flight: Flight
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(flight.airlineName).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(flight.flightNumber).font(.subheadline.bold()).foregroundStyle(.tint)
                }
                Text(flight.departureDay).font(.caption).foregroundStyle(.secondary)
                // Equal-width columns either side of the arrow — a pair of plain
                // Spacers split the space evenly, but that only lands in the true
                // centre when the two city names happen to be the same width.
                HStack(spacing: 0) {
                    VStack(alignment: .leading) { Text(flight.departure).font(.title3.bold()); Text(flight.departureAirport?.city ?? "").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.tint)
                    VStack(alignment: .trailing) { Text(flight.arrival).font(.title3.bold()); Text(flight.arrivalAirport?.city ?? "").font(.caption).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

private struct StatsPanel: View {
    let stats: TravelStats
    private var metric: Bool { systemPrefersMetric() }
    private var distanceText: String {
        if metric { return stats.totalDistanceKm.formatted() }
        let miles: Double = Double(stats.totalDistanceKm) * 0.621371
        return Int(miles).formatted()
    }
    var body: some View {
        HStack {
            StatCell(value: distanceText, unit: metric ? "km" : "mi", label: "Distance")
            StatCell(value: "\(stats.flightCount)", unit: "", label: "Flights")
            StatCell(value: "\(stats.countryCount)", unit: "", label: "Countries")
            StatCell(value: "\(stats.cityCount)", unit: "", label: "Cities")
        }
        .padding(.vertical, 16).padding(.horizontal, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct StatCell: View {
    let value: String, unit: String, label: String
    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold())
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
