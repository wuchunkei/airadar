import Foundation

/// What the phone tells the watch — just enough for a glanceable card and a
/// short list, with every date already resolved to a real instant (the
/// watch has no airport-timezone database of its own, so it never has to).
/// Sent whole, replacing the last one, whenever FlightStore's own list
/// changes (WatchSync.swift, phone side); read back verbatim by the watch
/// app and its complications (WatchStore.swift / AiradarWatchWidget).
struct WatchTrip: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let flightNumber: String
    let airlineName: String
    let departure: String
    let arrival: String
    let departureCity: String
    let arrivalCity: String
    let departureTerminal: String?
    let departureGate: String?
    let arrivalGate: String?
    let departureDate: Date
    let arrivalDate: Date
    let statusLabel: String
    let statusKind: WatchStatusKind
    let delayMinutes: Int
}

enum WatchStatusKind: String, Codable, Sendable { case scheduled, live, good, warn, bad }

struct WatchSnapshot: Codable, Sendable {
    /// Oldest first is not assumed anywhere that reads this — always sorted
    /// by departureDate before it's sent, so "first upcoming" is just "first".
    let trips: [WatchTrip]
    let generatedAt: Date

    static let empty = WatchSnapshot(trips: [], generatedAt: .distantPast)
}

/// Where the watch app and its widget extension both read the last snapshot
/// from — an App Group container, since a WidgetKit extension is its own
/// process and can't reach into the watch app's own storage directly.
enum WatchSnapshotStore {
    static let appGroup = "group.com.airadar.app"
    private static let key = "snapshot"

    static func save(_ snapshot: WatchSnapshot) {
        guard let data = try? JSONEncoder.watch.encode(snapshot) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: key)
    }

    static func load() -> WatchSnapshot {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let snapshot = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) else { return .empty }
        return snapshot
    }
}

extension JSONEncoder {
    static let watch: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

extension JSONDecoder {
    static let watch: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
