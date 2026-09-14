import Foundation

enum Tier: String, Codable, Sendable { case guest, superior, premium }

/// What a tier allows; nil means no limit. Mirrors billing.py on the server.
struct Limits: Sendable {
    let maxPastTrips: Int?
    /// Trips in the air or ahead — Now and Coming together.
    let maxUpcomingTrips: Int?
    let maxTrips: Int?
    let futureDays: Int?
    let sharing: Bool

    static let guest = Limits(maxPastTrips: 1, maxUpcomingTrips: nil, maxTrips: 3, futureDays: 7, sharing: false)
    static let superior = Limits(maxPastTrips: 5, maxUpcomingTrips: 10, maxTrips: nil, futureDays: 30, sharing: true)
    static let premium = Limits(maxPastTrips: nil, maxUpcomingTrips: nil, maxTrips: nil, futureDays: nil, sharing: true)

    static func of(_ tier: Tier) -> Limits {
        switch tier { case .guest: .guest; case .superior: .superior; case .premium: .premium }
    }
}

struct Membership: Codable, Hashable, Sendable {
    var tier: Tier
    var until: Date?
    var grace: Bool = false

    var limits: Limits { Limits.of(tier) }
    static let guest = Membership(tier: .guest, until: nil)
}

/// A token the traveller entered and the server accepted for this phone — before or without sign-in.
struct CheckedToken: Codable, Hashable, Sendable {
    let token: String
    let tier: Tier
    let until: Date
    let boundEmail: String?
}

enum Plans {
    static let superiorPrice = "US$1 / month"
    static let premiumPrice = "US$5 / month"
    static var payURL: URL { URL(string: Config.backendURL + "/pay")! }
}

/// Why a trip could not be added under the current plan.
struct LimitReached: Error, Identifiable, Sendable {
    let reason: String
    let tier: Tier
    var id: String { reason }
}

/// The client-side gate; signed in, the server enforces the same rules and this just saves a 402.
enum Entitlements {
    static var membership: Membership {
        AuthStore.shared.isSignedIn ? (AuthStore.shared.user?.membership ?? .guest) : .guest
    }

    static func checkAdd(_ flight: Flight, existing: [Flight]) throws(LimitReached) {
        let m = membership
        let lim = m.limits
        let live = existing.filter { $0.deletedAt == nil && $0.sharedBy == nil }
        if live.contains(where: { $0.id == flight.id }) { return }
        let today = LocalDateTime.from(Date(), in: .current).dayString
        let day = flight.departureDay
        let past = live.filter { $0.departureDay < today }.count

        if let max = lim.maxTrips, live.count >= max {
            throw LimitReached(reason: "\(max) trips is the most this plan keeps.", tier: m.tier)
        }
        if day < today, let max = lim.maxPastTrips, past >= max {
            throw LimitReached(reason: "This plan keeps \(max) past trip\(max == 1 ? "" : "s").", tier: m.tier)
        }
        if day >= today, let max = lim.maxUpcomingTrips, live.count - past >= max {
            throw LimitReached(reason: "This plan keeps \(max) trips ahead at a time.", tier: m.tier)
        }
        if day > today, let days = lim.futureDays {
            let cal = Calendar.current
            let now = cal.startOfDay(for: Date())
            if let d = cal.date(from: flight.departureTime.localDate),
               let diff = cal.dateComponents([.day], from: now, to: d).day, diff > days {
                throw LimitReached(reason: "This plan adds trips up to \(days) days ahead.", tier: m.tier)
            }
        }
    }
}
