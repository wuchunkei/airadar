import Foundation
import MapKit

/// Which terminals an airport actually has — a hand-checked correction first
/// (`AirportDatabase.terminals`), else whatever Apple's own map data finds
/// nearby, searched by name so it reaches any airport on Earth without a
/// hand-built database behind it. Some airports (Zhuhai's ZUH, say) have no
/// numbered terminals at all, just a Departure Hall and an Arrival Hall —
/// searched for by name too, since "Terminal" alone would never find those.
/// Shared by the "My" airport info sheet and the manual-entry form's terminal
/// picker, so there is exactly one place that knows how to ask.
enum TerminalDiscovery {
    /// What a traveller could actually pick from today — a hand-checked
    /// correction's open terminals, or (no correction on file) whatever
    /// Apple's map data finds. Never both.
    static func availableTerminals(for airport: Airport) async -> [String] {
        if let known = AirportDatabase.shared.terminals(airport.iata) {
            return known.filter { !$0.closed }.map(\.name)
        }
        return await discover(airport)
    }

    /// Every "Terminal N" (or "Departure"/"Arrival" hall) Apple's own map data
    /// has near this airport — the same search a traveller typing into Maps
    /// would get. Says nothing about whether a result is actually open;
    /// that's only known where it's been hand-checked into `AirportDatabase`.
    static func discover(_ airport: Airport) async -> [String] {
        async let terminals = search(airport, keyword: "Terminal")
        async let departures = search(airport, keyword: "Departure")
        async let arrivals = search(airport, keyword: "Arrival")
        var seen: Set<String> = []
        var out: [String] = []
        for label in await terminals + departures + arrivals where seen.insert(label).inserted {
            out.append(label)
        }
        return out
    }

    /// `region` is only a ranking hint to MKLocalSearch, not a hard filter — a
    /// smaller airport with no "Terminal N" of its own indexed can still hand
    /// back some other airport's terminal entirely (this is how a Haikou
    /// search once came back with Hong Kong's Terminal 1). So a result only
    /// counts if it is actually near the airport it was searched for.
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
    /// "Departure" (there's no number to normalize); nil for a place whose
    /// name says none of these (the airport itself, a lounge, a car park, …).
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

    /// "Departure"/"Arrival" read as themselves; anything else reads as
    /// "Terminal 1", "Terminal 3", … — the one place this gets decided, shared
    /// by every picker and info row that shows a terminal name.
    static func displayLabel(_ terminal: String) -> String {
        ["Departure", "Arrival"].contains(terminal) ? terminal : "Terminal \(terminal)"
    }
}
