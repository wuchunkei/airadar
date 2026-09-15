import SwiftUI

/// Full-screen map of every leg flown — bowed arcs only, never the raw jagged
/// ADS-B trail, coloured by direction (blue north, green south) rather than by
/// trip — with the stats panel at the bottom and Settings at the top right. Tap
/// a leg (or an airport dot) for the trips that flew it.
struct MyView: View {
    @EnvironmentObject private var store: FlightStore
    @EnvironmentObject private var settings: SettingsModel

    @State private var selectedLegs: [(Airport, Airport)] = []
    @State private var openId: String?
    @State private var showSettings = false
    @State private var homeRegion: Region?
    @State private var trackStatus: [String: TrackStatus] = [:]

    /// Flown legs, and the one in the air right now with the plane on it.
    private var history: [Flight] { store.flights.filter { ($0.phase == .past || $0.phase == .inProgress) && !$0.isPending } }
    /// Every leg as a bowed arc — never the real recorded track, which kinks and
    /// looks jagged at the zoomed-out scale this overview is seen at. The one in
    /// the air still gets its dashed-ahead / solid-flown split, timed by the clock.
    private var routes: [MapRoute] { history.toMapRoutes() }
    private var legFlights: [Flight] {
        history.filter { f in selectedLegs.contains { f.departure == $0.0.iata && f.arrival == $0.1.iata } }
            .sorted { ($0.departureInstant ?? .distantPast) > ($1.departureInstant ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // Full-bleed, as it was — direction tells the colour: blue heading
                // north, green heading south, so the web of past legs reads at a glance.
                TileMapView(routes: routes, interactive: true, directionColored: true, selected: selectedLegs, emptyFocus: homeRegion,
                            onLegTap: { selectedLegs = $0 }, onMapTap: { selectedLegs = [] })
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    if !legFlights.isEmpty {
                        // Same width as the stats panel; several flights on one leg page sideways.
                        TabView {
                            ForEach(legFlights) { f in
                                LegCard(flight: f) { openId = f.id }
                                    .padding(.horizontal, 12)
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
        }
        .sheet(item: $openId) { id in
            if let f = store.flights.first(where: { $0.id == id }) {
                FlightDetailSheet(flight: f, forceSystemZone: settings.forceSystemZone, trackStatus: trackStatus[f.id],
                                  onLoadTrack: { load(f) }, onDismiss: { openId = nil })
            }
        }
    }

    private func load(_ f: Flight) {
        trackStatus[f.id] = .loading
        Task {
            do {
                let t = try await OpenSkyClient.shared.fetchTrack(f)
                store.setTrack(f.id, points: t.points, flownOn: t.flownOn)
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
                HStack {
                    VStack(alignment: .leading) { Text(flight.departure).font(.title3.bold()); Text(flight.departureAirport?.city ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.tint)
                    Spacer()
                    VStack(alignment: .trailing) { Text(flight.arrival).font(.title3.bold()); Text(flight.arrivalAirport?.city ?? "").font(.caption).foregroundStyle(.secondary) }
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
