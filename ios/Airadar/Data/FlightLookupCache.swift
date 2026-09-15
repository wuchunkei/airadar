import Foundation

/// One flight's answer from the backend's own `/flights/{number}/{day}` — the
/// same endpoint search already uses, AirLabs first and AeroDataBox behind it
/// when AirLabs has nothing — kept on disk so a flight already found to need
/// this (OpenSky's track came up empty) isn't asked about again every time
/// its detail sheet opens. Every key — AirLabs', AeroDataBox's — lives on the
/// server; this device never holds one.
@MainActor
final class FlightLookupCache {
    static let shared = FlightLookupCache()

    /// A key present but holding nil means "asked, the backend had nothing" —
    /// still worth remembering, so a flight neither source covers isn't asked
    /// about on every visit.
    private struct Entry: Codable { let flight: Flight? }
    private var byFlightId: [String: Entry] = [:]

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flight-lookup-cache.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL) {
            byFlightId = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }

    /// Outer nil: never asked. Inner nil: asked, nothing found.
    func result(for flightId: String) -> Flight?? {
        byFlightId[flightId].map { $0.flight }
    }

    func remember(_ flightId: String, _ flight: Flight?) {
        byFlightId[flightId] = Entry(flight: flight)
        let snapshot = byFlightId
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.cacheURL, options: .atomic) }
        }
    }
}
