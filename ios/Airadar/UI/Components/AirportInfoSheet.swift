import SwiftUI
import MapKit

/// What tapping an airport's dot on the map opens: the airport itself, not its
/// flights — name, code, every terminal it actually has, worldwide (not just
/// the ones your own trips happened to use — Apple's own map data supplies the
/// rest, a hand-checked correction standing in only where that data is stale)
/// with how many of your flights went through each, and from each a driving
/// and a transit time with a button that starts navigating that way.
struct AirportInfoSheet: View {
    let airport: Airport
    /// To tally which terminals this airport's own flights have used.
    let history: [Flight]

    @State private var driveETA: Result<TimeInterval, Error>?
    @State private var transitETA: Result<TimeInterval, Error>?
    @State private var terminalRows: [(terminal: String, count: Int, closed: Bool)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(airport.city) · \(airport.iata)/\(airport.icao)").font(.title2.bold())
                    Text(airport.name).foregroundStyle(.secondary)
                    Text(airport.country).font(.subheadline).foregroundStyle(.secondary)
                }

                if !terminalRows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Terminals").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.bottom, 10)
                        ForEach(Array(terminalRows.enumerated()), id: \.element.terminal) { i, row in
                            if i > 0 { Divider().padding(.vertical, 12) }
                            TerminalRow(airport: airport, terminal: row.terminal, flightCount: row.count, closed: row.closed,
                                        driveETA: driveETA, transitETA: transitETA)
                        }
                    }
                }
            }
            .padding(20)
        }
        .task(id: airport.iata) { await loadETAs() }
        .task(id: airport.iata) { await loadTerminals() }
    }

    /// Your own recorded terminals first (instant, and always right about your
    /// own trips); then either a hand-checked correction or, for every other
    /// airport on Earth, whatever terminals Apple's own map data finds nearby.
    private func loadTerminals() async {
        var counts: [String: Int] = [:]
        for f in history {
            if f.departure == airport.iata, let t = f.departureTerminal, !t.isEmpty { counts[normalizeTerminal(t), default: 0] += 1 }
            if f.arrival == airport.iata, let t = f.arrivalTerminal, !t.isEmpty { counts[normalizeTerminal(t), default: 0] += 1 }
        }

        let names: [(name: String, closed: Bool)]
        if let known = AirportDatabase.shared.terminals(airport.iata) {
            names = known.map { ($0.name, $0.closed) }
        } else {
            let discovered = await Self.discoverTerminals(airport)
            names = discovered.isEmpty ? counts.keys.map { ($0, false) } : discovered
        }

        terminalRows = names.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { (terminal: $0.name, count: counts[$0.name] ?? 0, closed: $0.closed) }
    }

    /// Every "Terminal N" Apple's own map data has near this airport — the
    /// same search a traveller typing into Maps would get, so it reaches any
    /// airport on Earth without a hand-built database behind it. Some airports
    /// (Zhuhai's ZUH, say) have no numbered terminals at all, just a Departure
    /// Hall and an Arrival Hall — searched for by name too, since "Terminal"
    /// alone would never turn those up. Nothing here says whether a result is
    /// closed — Apple's search doesn't carry that — so a discovered one is
    /// only ever assumed open; a closed one only shows as such where it's
    /// been hand-checked into `AirportDatabase`.
    private static func discoverTerminals(_ airport: Airport) async -> [(name: String, closed: Bool)] {
        async let terminals = search(airport, keyword: "Terminal")
        async let departures = search(airport, keyword: "Departure")
        async let arrivals = search(airport, keyword: "Arrival")
        var seen: Set<String> = []
        var out: [(String, Bool)] = []
        for label in await terminals + departures + arrivals where seen.insert(label).inserted {
            out.append((label, false))
        }
        return out
    }

    private static func search(_ airport: Airport, keyword: String) async -> [String] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(airport.name) \(keyword)"
        request.region = MKCoordinateRegion(center: airport.coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let target = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        return response.mapItems.compactMap { item in
            guard item.location.distance(from: target) < 15_000, let name = item.name else { return nil }
            return extractLabel(name)
        }
    }

    /// "Terminal 1", "Terminal T1 Building" → "1"; "Departure Hall" → literally
    /// "Departure" (there's no number to normalize); nil for a place whose name
    /// says none of these (the airport itself, a lounge, a car park, …).
    private static func extractLabel(_ name: String) -> String? {
        if let r = name.range(of: "Terminal", options: .caseInsensitive) {
            let token = name[r.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber }
            return token.isEmpty ? nil : normalizeTerminal(String(token))
        }
        for word in ["Departure", "Arrival"] where name.range(of: word, options: .caseInsensitive) != nil {
            return word
        }
        return nil
    }

    private func loadETAs() async {
        guard let origin = await HomeRegion.coarseCoordinate() else {
            let noLocation = LocationUnavailable()
            driveETA = .failure(noLocation); transitETA = .failure(noLocation)
            return
        }
        async let drive = DirectionsETA.seconds(from: origin, to: airport.coordinate, by: .automobile)
        async let transit = DirectionsETA.seconds(from: origin, to: airport.coordinate, by: .transit)
        driveETA = await drive.map(Result.success) ?? .failure(RouteUnavailable())
        transitETA = await transit.map(Result.success) ?? .failure(RouteUnavailable())
    }

    private struct LocationUnavailable: Error {}
    private struct RouteUnavailable: Error {}
}

/// One terminal: its name — blue and tappable, opening that terminal's own
/// place card in Apple Maps, unless it's closed, in which case there is
/// nowhere to send anyone and the name is just plain text — how many of your
/// flights used it, and, when open, the two ways to actually get there.
private struct TerminalRow: View {
    let airport: Airport
    let terminal: String
    let flightCount: Int
    let closed: Bool
    let driveETA: Result<TimeInterval, Error>?
    let transitETA: Result<TimeInterval, Error>?

    /// The terminal's own place, once Apple Maps' own search has found it —
    /// nil (fine) just means the button falls back to the airport as a whole.
    @State private var resolved: MKMapItem?

    /// "Departure"/"Arrival" (an airport with halls, not numbered terminals)
    /// read as themselves; anything else reads as "Terminal 1", "Terminal 3", …
    private var label: String { ["Departure", "Arrival"].contains(terminal) ? terminal : "Terminal \(terminal)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if closed {
                    Text(label).fontWeight(.semibold)
                    Text("· closed").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: openPlaceCard) {
                        Text(label).foregroundStyle(.blue).fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if flightCount > 0 {
                    Text("\(flightCount) flight\(flightCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !closed {
                HStack(spacing: 8) {
                    etaButton(icon: "car.fill", result: driveETA, transportType: .automobile)
                    etaButton(icon: "tram.fill", result: transitETA, transportType: .transit)
                }
            }
        }
        .task { if !closed { resolved = await Self.resolve(airport: airport, terminal: terminal) } }
    }

    private func etaButton(icon: String, result: Result<TimeInterval, Error>?, transportType: MKDirectionsTransportType) -> some View {
        let time: String = {
            switch result {
            case .success(let seconds): formatDuration(Int((seconds / 60).rounded()))
            case .failure: "N/A"
            case nil: "…"
            }
        }()
        return Button { navigate(by: transportType) } label: {
            HStack(spacing: 6) { Image(systemName: icon); Text(time) }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled({ if case .success = result { false } else { true } }())
    }

    /// `region` is only a ranking hint to MKLocalSearch, not a hard filter — a
    /// smaller airport with no "Terminal N" of its own indexed can still hand
    /// back some other airport's terminal entirely (this is how a Haikou search
    /// once came back with Hong Kong's Terminal 1). So the result only counts if
    /// it is actually near the airport it was searched for.
    private static func resolve(airport: Airport, terminal: String) async -> MKMapItem? {
        let label = ["Departure", "Arrival"].contains(terminal) ? terminal : "Terminal \(terminal)"
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(airport.name) \(label)"
        request.region = MKCoordinateRegion(center: airport.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let target = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        return item.location.distance(from: target) < 15_000 ? item : nil
    }

    /// The terminal's own info card — Call, Website, photos — the same as
    /// tapping it by hand in Apple Maps. No directions started yet.
    private func openPlaceCard() {
        (resolved ?? fallbackItem()).openInMaps()
    }

    private func navigate(by transportType: MKDirectionsTransportType) {
        let mode = transportType == .transit ? MKLaunchOptionsDirectionsModeTransit : MKLaunchOptionsDirectionsModeDriving
        (resolved ?? fallbackItem()).openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }

    private func fallbackItem() -> MKMapItem {
        let item = MKMapItem(location: CLLocation(latitude: airport.latitude, longitude: airport.longitude), address: nil)
        item.name = "\(airport.name) — \(label)"
        return item
    }
}
