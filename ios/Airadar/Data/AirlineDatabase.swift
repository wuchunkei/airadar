import Foundation

/// Every active airline IATA-coded worldwide, bundled once from OpenFlights'
/// long-standing public dataset (github.com/jpatokal/openflights) — free, no
/// network needed, works offline. It is not live: OpenFlights itself is only
/// occasionally updated, so a very recently renamed or newly launched carrier
/// may be missing or out of date. That's what "Other" and a suggestion are
/// for — see `AirlineSuggestion`.
struct AirlineInfo: Codable, Hashable, Sendable {
    let name: String
    let iata: String
    let icao: String
    let country: String
}

final class AirlineDatabase: @unchecked Sendable {
    static let shared = AirlineDatabase()

    private let byIATA: [String: AirlineInfo]
    private let all: [AirlineInfo]

    private init() {
        guard let url = Bundle.main.url(forResource: "airlines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([AirlineInfo].self, from: data) else {
            byIATA = [:]; all = []
            return
        }
        all = list
        byIATA = Dictionary(uniqueKeysWithValues: list.map { ($0.iata, $0) })
    }

    func airline(iata: String) -> AirlineInfo? { byIATA[iata.uppercased()] }

    /// Up to `limit` airlines whose name or IATA code starts with `query` —
    /// name matches first, then by name. Empty for a blank query.
    func search(_ query: String, limit: Int = 20) -> [AirlineInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let upper = q.uppercased()
        let byCode = all.filter { $0.iata == upper }
        let byName = all.filter { $0.iata != upper && $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Array((byCode + byName).prefix(limit))
    }
}

/// A traveller's own correction — an airline the bundled table doesn't have,
/// or has wrong — staged on this device until there is somewhere real to send
/// it. TODO once the backend has a pending-approval endpoint and SMTP is
/// configured: POST these and have the server mail wuchunkeijohn@gmail.com to
/// review each one; for now they just sit here so nothing is lost.
struct AirlineSuggestion: Codable, Sendable, Identifiable {
    let id: String
    let flightNumber: String
    let suggestedName: String
    let createdAt: Date
}

@MainActor
final class AirlineSuggestionStore: ObservableObject {
    static let shared = AirlineSuggestionStore()
    @Published private(set) var pending: [AirlineSuggestion] = []

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("airline-suggestions.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL) {
            pending = (try? JSONDecoder().decode([AirlineSuggestion].self, from: data)) ?? []
        }
    }

    func submit(flightNumber: String, name: String) {
        pending.append(AirlineSuggestion(id: UUID().uuidString, flightNumber: flightNumber, suggestedName: name, createdAt: Date()))
        let snapshot = pending
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.cacheURL, options: .atomic) }
        }
    }
}
