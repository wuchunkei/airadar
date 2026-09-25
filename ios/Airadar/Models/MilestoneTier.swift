import SwiftUI

/// The nine visible tiers, plus one hidden one above them — run the way a
/// real airline's elite tiers are: promotion happens on legs flown OR
/// distance flown SINCE THE LAST RANK-UP, whichever gets there first, and
/// both counters reset to zero the moment that happens — a long-haul
/// traveller and a short-hop commuter both climb, just by different
/// arithmetic, and neither a single mega-flight nor a burst of short hops
/// vaults more than one tier at a time. (The lifetime flight total shown
/// elsewhere — My's own stats panel — is a separate, never-reset count;
/// it just isn't what decides a rank-up.)
///
/// Porcelain (751+ legs) is a secret: nothing before it hints it exists, and
/// reaching it is rare enough that it also carries a sequence number — the
/// Nth traveller ever to get there — awarded by the backend, never the
/// client (`BackendClient.claimPorcelain`). It's the true ceiling this
/// ladder used to call Rainbow — renamed, and split off from what used to
/// be one enormous top band (Obsidian, then Rainbow) into three narrower
/// ones (Amber, Silk, Porcelain) so the climb from Ruby onward still feels
/// like a series of rank-ups, not one long plateau.
///
/// 首飛 (First Flight) has its own artwork but isn't a rung on this ladder —
/// it's a one-off "flew at all" stamp, unlocked at leg 1 regardless of tier,
/// parked for now (its own place in the UI is a later pass).
enum MilestoneTier: Int, CaseIterable, Comparable {
    case blackIron, bronze, silver, gold, platinum, diamond, ruby, amber, silk, porcelain

    static func < (a: MilestoneTier, b: MilestoneTier) -> Bool { a.rawValue < b.rawValue }

    /// The average distance of a leg, used to convert a tier's leg-width
    /// into an equivalent km budget — the traveller's own figure.
    static let averageKmPerLeg = 1157

    /// The lifetime leg-count band this tier owns — legs 1-10 are Black
    /// Iron, 11-20 Bronze, and so on, however a traveller actually gets
    /// there (some ranks up early on distance, see `TierStanding.compute`).
    var legBand: ClosedRange<Int> {
        switch self {
        case .blackIron: 1...10
        case .bronze: 11...20
        case .silver: 21...30
        case .gold: 31...50
        case .platinum: 51...75
        case .diamond: 76...100
        case .ruby: 101...250
        case .amber: 251...450
        case .silk: 451...750
        case .porcelain: 751...Int.max
        }
    }

    /// The band's width in legs — Porcelain, the true ceiling, has none.
    var legsInBand: Int { self == .porcelain ? Int.max : legBand.upperBound - legBand.lowerBound + 1 }

    /// The band's width converted to km at the average leg length — the
    /// budget that resets to zero every time a rank-up happens.
    var kmBudget: Int { legsInBand == Int.max ? Int.max : legsInBand * Self.averageKmPerLeg }

    var next: MilestoneTier? {
        let ordered = Self.allCases.sorted()
        guard let i = ordered.firstIndex(of: self), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    var name: String {
        switch self {
        case .blackIron: String(localized: "Black Iron")
        case .bronze: String(localized: "Bronze")
        case .silver: String(localized: "Silver")
        case .gold: String(localized: "Gold")
        case .platinum: String(localized: "Platinum")
        case .diamond: String(localized: "Diamond")
        case .ruby: String(localized: "Ruby")
        case .amber: String(localized: "Amber")
        case .silk: String(localized: "Silk")
        case .porcelain: String(localized: "Porcelain")
        }
    }

    /// Only ever shown for the tier with no next — today just Porcelain.
    var tagline: String {
        switch self {
        case .blackIron: String(localized: "Every journey starts here.")
        case .bronze: String(localized: "Ten flights and counting.")
        case .silver: String(localized: "A quarter-century in the air.")
        case .gold: String(localized: "Fifty flights strong.")
        case .platinum: String(localized: "Triple digits — a real habit now.")
        case .diamond: String(localized: "Diamond-clear dedication.")
        case .ruby: String(localized: "Two-fifty, and still climbing.")
        case .amber: String(localized: "Preserved in flight, one leg at a time.")
        case .silk: String(localized: "Smooth as the old trade routes.")
        case .porcelain: String(localized: "A secret worth finding.")
        }
    }

    /// The real artwork's file key — `tier-<key>-logo.png` under
    /// `Resources/Tiers`. Placeholder gradients only kick in if a file is
    /// ever missing (a tier added here before its art arrives, say).
    var artKey: String {
        switch self {
        case .blackIron: "blackiron"
        case .bronze: "bronze"
        case .silver: "silver"
        case .gold: "gold"
        case .platinum: "platinum"
        case .diamond: "diamond"
        case .ruby: "ruby"
        case .amber: "amber"
        case .silk: "silk"
        case .porcelain: "porcelain"
        }
    }

    /// Placeholder centre → edge palette — only ever seen if `artKey`'s
    /// file is missing from the bundle.
    var gradient: [Color] {
        switch self {
        case .blackIron: [Color(red: 0.24, green: 0.25, blue: 0.27), Color(red: 0.09, green: 0.09, blue: 0.11)]
        case .bronze: [Color(red: 0.88, green: 0.66, blue: 0.47), Color(red: 0.54, green: 0.29, blue: 0.17)]
        case .silver: [Color(red: 0.96, green: 0.96, blue: 0.97), Color(red: 0.62, green: 0.64, blue: 0.67)]
        case .gold: [Color(red: 1.00, green: 0.95, blue: 0.69), Color(red: 0.79, green: 0.58, blue: 0.10)]
        case .platinum: [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.66, green: 0.72, blue: 0.77)]
        case .diamond: [Color(red: 0.92, green: 0.99, blue: 1.00), Color(red: 0.37, green: 0.75, blue: 0.88)]
        case .ruby: [Color(red: 1.00, green: 0.54, blue: 0.54), Color(red: 0.48, green: 0.05, blue: 0.12)]
        case .amber: [Color(red: 1.00, green: 0.82, blue: 0.40), Color(red: 0.72, green: 0.42, blue: 0.05)]
        case .silk: [Color(red: 0.98, green: 0.90, blue: 0.86), Color(red: 0.80, green: 0.63, blue: 0.58)]
        case .porcelain: [Color(red: 0.98, green: 0.99, blue: 1.00), Color(red: 0.55, green: 0.65, blue: 0.82)]
        }
    }

    var rimColor: Color {
        switch self {
        case .blackIron: Color(red: 0.36, green: 0.38, blue: 0.41)
        case .bronze: Color(red: 0.79, green: 0.48, blue: 0.24)
        case .silver: Color(red: 0.79, green: 0.80, blue: 0.82)
        case .gold: Color(red: 0.95, green: 0.79, blue: 0.30)
        case .platinum: Color(red: 0.81, green: 0.88, blue: 0.93)
        case .diamond: Color(red: 0.74, green: 0.94, blue: 1.00)
        case .ruby: Color(red: 0.85, green: 0.12, blue: 0.25)
        case .amber: Color(red: 0.88, green: 0.56, blue: 0.10)
        case .silk: Color(red: 0.90, green: 0.75, blue: 0.70)
        case .porcelain: Color(red: 0.30, green: 0.42, blue: 0.68)
        }
    }
}

/// Where a traveller actually stands: the tier reached after walking every
/// completed flight in order, and how many legs and how many km have
/// counted toward the CURRENT tier so far — both reset to zero at every
/// rank-up, which is what makes "legs or km, whichever first" a real race
/// tier by tier instead of a one-time fuse.
struct TierStanding {
    let tier: MilestoneTier
    let legsIntoTier: Int
    let kmIntoTier: Int

    var legsToNext: Int? { tier.next.map { _ in max(0, tier.legsInBand - legsIntoTier) } }
    var kmToNext: Int? { tier.next.map { _ in max(0, tier.kmBudget - kmIntoTier) } }

    /// Every completed flight, oldest first, feeds both counters; whichever
    /// hits the current tier's budget first promotes — same as an airline
    /// combining segments and miles toward the same rank-up.
    static func compute(for flights: [Flight]) -> TierStanding {
        let ordered = flights.sorted { ($0.departureInstant ?? .distantPast) < ($1.departureInstant ?? .distantPast) }
        var tier = MilestoneTier.blackIron
        var legs = 0, km = 0
        for f in ordered {
            legs += 1
            km += f.distanceKm
            while tier.next != nil, legs >= tier.legsInBand || km >= tier.kmBudget {
                tier = tier.next!
                legs = 0; km = 0
            }
        }
        return TierStanding(tier: tier, legsIntoTier: legs, kmIntoTier: km)
    }
}

/// The medallion — real per-tier artwork when it's in the bundle
/// (`Resources/Tiers/tier-<key>-logo.png`), a placeholder gradient if not.
struct TierBadgeView: View {
    let tier: MilestoneTier
    var size: CGFloat = 28

    private static var cache: [String: UIImage] = [:]
    private var art: UIImage? {
        if let cached = Self.cache[tier.artKey] { return cached }
        guard let url = Bundle.main.url(forResource: "tier-\(tier.artKey)-logo", withExtension: "png"),
              let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        Self.cache[tier.artKey] = image
        return image
    }

    var body: some View {
        Group {
            if let art {
                Image(uiImage: art).resizable().scaledToFit()
            } else {
                ZStack {
                    Circle().fill(RadialGradient(colors: tier.gradient, center: UnitPoint(x: 0.35, y: 0.32), startRadius: 0, endRadius: size * 0.75))
                    Circle().strokeBorder(tier.rimColor, lineWidth: max(1.5, size * 0.07))
                    Image(systemName: "airplane").font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white).rotationEffect(.degrees(45))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    /// A plain linear blend toward `other` — used to fade the route-progress
    /// plane and its flown line from one tier's colour into the next's as
    /// it moves along, rather than snapping from one to the other.
    func mixed(with other: Color, fraction: Double) -> Color {
        let f = min(1, max(0, fraction))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, opacity: a1 + (a2 - a1) * f)
    }
}
