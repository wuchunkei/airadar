import Foundation

enum Tier: String, Codable, Sendable { case guest, premium }

/// What a tier allows; nil means no limit. Mirrors billing.py on the server.
struct Limits: Sendable {
    /// Trips in the air or ahead — Now and Coming together.
    let maxUpcomingTrips: Int?
    /// How far back a past trip may be added, or kept appearing once synced.
    let pastDays: Int?
    let futureDays: Int?

    static let guest = Limits(maxUpcomingTrips: 1, pastDays: 7, futureDays: nil)
    static let premium = Limits(maxUpcomingTrips: nil, pastDays: nil, futureDays: nil)

    static func of(_ tier: Tier) -> Limits {
        switch tier { case .guest: .guest; case .premium: .premium }
    }
}

struct Membership: Codable, Hashable, Sendable {
    var tier: Tier
    var until: Date?
    var grace: Bool = false
    /// The Share add-on — its own small subscription, held or not
    /// independent of `tier`; a guest can have it, a Premium member might not.
    var canShare: Bool = false

    var limits: Limits { Limits.of(tier) }
    static let guest = Membership(tier: .guest, until: nil)

    init(tier: Tier, until: Date?, grace: Bool = false, canShare: Bool = false) {
        self.tier = tier; self.until = until; self.grace = grace; self.canShare = canShare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = (try? c.decode(Tier.self, forKey: .tier)) ?? .guest
        until = try c.decodeIfPresent(Date.self, forKey: .until)
        grace = try c.decodeIfPresent(Bool.self, forKey: .grace) ?? false
        canShare = try c.decodeIfPresent(Bool.self, forKey: .canShare) ?? false
    }

    private enum CodingKeys: String, CodingKey { case tier, until, grace, canShare }
}

/// A token the traveller entered and the server accepted for this phone — before or without sign-in.
struct CheckedToken: Codable, Hashable, Sendable {
    let token: String
    let tier: Tier
    let until: Date?  // nil for a lifetime or one-time-buyout token
    let boundEmail: String?
}

enum Plans {
    static let premiumPrice = "US$5 / month"
    static let premiumBuyoutPrice = "US$50 once"
    static let sharePrice = "US$0.99 / month"
    static var payURL: URL { URL(string: Config.backendURL + "/pay")! }
}

/// Why a trip could not be added under the current plan.
struct LimitReached: Error, Identifiable, Sendable {
    let reason: String
    let tier: Tier
    var id: String { reason }
}

/// The client-side gate; signed in, the server enforces the same rules and this just saves a 402.
@MainActor
enum Entitlements {
    /// Off while the token/paywall page is shelved (see SettingsView's
    /// Account section) — everyone gets Premium's limits, which is to say
    /// none, signed in or not. Flip this back on — and bring back the
    /// token entry UI it's paired with — to restore gating behind sign-in
    /// + token, or an Apple/Google IAP flow, later; billing.py's
    /// `PAYWALL_ENABLED` is the matching switch on the server.
    static let paywallEnabled = false

    static var membership: Membership {
        guard paywallEnabled else { return Membership(tier: .premium, until: nil, canShare: true) }
        return AuthStore.shared.isSignedIn ? (AuthStore.shared.user?.membership ?? .guest) : .guest
    }

    static func checkAdd(_ flight: Flight, existing: [Flight]) throws(LimitReached) {
        guard paywallEnabled else { return }
        let m = membership
        let lim = m.limits
        let live = existing.filter { $0.deletedAt == nil && $0.sharedBy == nil }
        if live.contains(where: { $0.id == flight.id }) { return }
        let today = LocalDateTime.from(Date(), in: .current).dayString
        let day = flight.departureDay

        if day < today, let days = lim.pastDays {
            let cal = Calendar.current
            let now = cal.startOfDay(for: Date())
            if let d = cal.date(from: flight.departureTime.localDate),
               let diff = cal.dateComponents([.day], from: d, to: now).day, diff > days {
                throw LimitReached(reason: "This plan adds past trips up to \(days) days back.", tier: m.tier)
            }
        }
        if day > today, let days = lim.futureDays {
            let cal = Calendar.current
            let now = cal.startOfDay(for: Date())
            if let d = cal.date(from: flight.departureTime.localDate),
               let diff = cal.dateComponents([.day], from: now, to: d).day, diff > days {
                throw LimitReached(reason: "This plan adds trips up to \(days) days ahead.", tier: m.tier)
            }
        }
        if day >= today, let max = lim.maxUpcomingTrips {
            let upcoming = live.filter { $0.departureDay >= today }.count
            if upcoming >= max {
                throw LimitReached(reason: "This plan keeps \(max) trip\(max == 1 ? "" : "s") ahead at a time.", tier: m.tier)
            }
        }
    }
}
