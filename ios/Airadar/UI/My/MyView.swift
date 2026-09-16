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
    /// The location button's own little state machine: centred by default: a
    /// pan away and the button just recentres; already centred and the button
    /// hides the dot outright; hidden and it shows and centres again.
    @State private var showsUserLocation = true
    @State private var trackingMode: MKUserTrackingMode = .follow
    /// The height of the card stack floating over the bottom of the map —
    /// measured, not guessed, since it grows or shrinks with the leg
    /// carousel appearing and disappearing. Centring on the user shifts up
    /// by half of this, so "my location" lands in the map that's actually
    /// free to look at above it.
    @State private var overlayHeight: CGFloat = 0

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

    /// The same three-way cycle Apple's own location button uses, plus a
    /// fourth: press it while already centred and the dot goes away outright,
    /// rather than just stopping the camera from following it. Opening My
    /// straight into "centred" is what makes tapping it immediately hide —
    /// there's nothing special-cased for that, it just falls out of the states.
    private func locationButtonTapped() {
        if !showsUserLocation {
            showsUserLocation = true
            trackingMode = .follow
        } else if trackingMode == .follow || trackingMode == .followWithHeading {
            showsUserLocation = false
            trackingMode = .none
        } else {
            trackingMode = .follow
        }
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
                            highlightedAirports: highlightedAirports, showsUserLocation: showsUserLocation,
                            userTrackingMode: $trackingMode, emptyFocus: homeRegion, bottomInset: overlayHeight,
                            onLegTap: legTapped, onAirportTap: airportTapped, onMapTap: { browsing = []; currentFlightId = nil })
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    // A route selected: its flights take this slot, oldest to
                    // newest; nothing selected: the tier card is back in it.
                    // Same height either way, so the layout doesn't jump.
                    if !browsing.isEmpty {
                        TabView(selection: $currentFlightId) {
                            ForEach(browsing) { f in
                                LegCard(flight: f) { openId = f.id }
                                    .padding(.horizontal, 12)
                                    .tag(f.id as String?)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 118)
                    } else {
                        TierProgressCard(standing: .compute(for: history), rainbowRank: store.rainbowRank)
                            .padding(.horizontal, 12)
                    }
                    StatsPanel(stats: history.travelStats())
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { overlayHeight = $0 }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: locationButtonTapped) {
                        Image(systemName: showsUserLocation && trackingMode != .none ? "location.fill" : "location")
                    }
                }
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
            // Only ever does anything once standing genuinely reads Rainbow.
            .task(id: history.count) { await store.refreshRainbowRank() }
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

/// The badge on the left, how far to the next tier on the right — sat just
/// above the Distance/Flights/Countries/Cities panel it's really an extra
/// row for.
/// The current tier's badge and the next one's, a route line flying between
/// them — flown so far solid and fading from one tier's colour into the
/// other's, still to go dashed — with the plane sat wherever that progress
/// actually is, and "N flights/N km still" written over the line itself.
/// Rainbow, with nothing beyond it, just shows the badge and its tagline.
private struct TierProgressCard: View {
    let standing: TierStanding
    /// Rainbow's sequence number, once the backend has handed one out —
    /// nil the whole time up to and including the moment standing first
    /// reads Rainbow but the claim hasn't come back yet.
    var rainbowRank: Int? = nil
    private var tier: MilestoneTier { standing.tier }
    private var next: MilestoneTier? { tier.next }

    /// Whichever of legs-into-tier or km-into-tier is further along is the
    /// one actually closest to promoting — that's where the plane sits.
    private var fraction: Double {
        guard tier.legsInBand != Int.max else { return 0 }
        let legs = Double(standing.legsIntoTier) / Double(tier.legsInBand)
        let km = Double(standing.kmIntoTier) / Double(tier.kmBudget)
        return min(1, max(legs, km))
    }

    /// "3 flights/4,200 km still" — both counters, since either reaching
    /// zero first is what actually promotes.
    private var remainingText: String {
        guard let legsToNext = standing.legsToNext, let kmToNext = standing.kmToNext else { return tier.tagline }
        let distance = systemPrefersMetric() ? "\(kmToNext.formatted()) km" : "\(Int(Double(kmToNext) * 0.621371).formatted()) mi"
        return "\(legsToNext) \(legsToNext == 1 ? "flight" : "flights")/\(distance) still"
    }

    private func label(_ t: MilestoneTier) -> some View {
        VStack(spacing: 3) {
            TierBadgeView(tier: t, size: 36)
            Text(t.name).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            label(tier)
            if let next {
                GeometryReader { g in
                    let w = g.size.width, midY = g.size.height / 2
                    let flownX = w * fraction
                    let planeColor = tier.rimColor.mixed(with: next.rimColor, fraction: fraction)
                    ZStack {
                        Path { p in p.move(to: CGPoint(x: flownX, y: midY)); p.addLine(to: CGPoint(x: w, y: midY)) }
                            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        Path { p in p.move(to: CGPoint(x: 0, y: midY)); p.addLine(to: CGPoint(x: flownX, y: midY)) }
                            .stroke(LinearGradient(colors: [tier.rimColor, planeColor], startPoint: .leading, endPoint: .trailing), lineWidth: 2.5)
                        Image(systemName: "airplane").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(planeColor)
                            .position(x: min(max(8, flownX), w - 8), y: midY)
                        Text(remainingText).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.background.opacity(0.85), in: .rect(cornerRadius: 4))
                            .fixedSize()
                            .position(x: w / 2, y: midY - 15)
                    }
                }
                .frame(height: 40)
                label(next)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tier.name).font(.subheadline.bold())
                        // Hidden tier, hidden bragging right: which-numbered
                        // traveller ever to get here, once the backend confirms it.
                        if let rainbowRank { Text("#\(rainbowRank)").font(.caption.bold()).foregroundStyle(.secondary) }
                    }
                    Text(tier.tagline).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        // Set on the HStack itself, before the glass background — set from
        // outside instead, the background would only wrap its content's own
        // natural (shorter) height and just float in extra empty space
        // rather than actually match the flight card's full 118pt bubble.
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118)
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
            StatCell(value: "\(stats.flightCount)", unit: "", label: "Flights")
            StatCell(value: distanceText, unit: metric ? "km" : "mi", label: "Distance")
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
