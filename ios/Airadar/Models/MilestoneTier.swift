import SwiftUI

/// The eight-tier status ladder, run the way a real airline's elite tiers
/// are: promotion happens on legs flown OR distance flown since the last
/// rank-up, whichever gets there first — a long-haul traveller and a
/// short-hop commuter both climb, just by different arithmetic. Lifetime
/// leg count never resets; the distance budget does, at every rank-up.
///
/// 首飛 (First Flight) has its own artwork but isn't a rung on this ladder —
/// it's a one-off "flew at all" stamp, unlocked at leg 1 regardless of tier,
/// with its own place in the UI still to be designed.
enum MilestoneTier: Int, CaseIterable, Comparable {
    case blackIron, bronze, silver, gold, platinum, diamond, ruby, obsidian

    static func < (a: MilestoneTier, b: MilestoneTier) -> Bool { a.rawValue < b.rawValue }

    /// The average distance of a leg, used to convert a tier's leg-width
    /// into an equivalent km budget — the traveller's own figure.
    static let averageKmPerLeg = 1157

    /// The lifetime leg-count band this tier owns — legs 1-10 are Black
    /// Iron, 11-20 Bronze, and so on, however a traveller actually gets
    /// there (some ranks up early on distance, see `standing(for:)`).
    var legBand: ClosedRange<Int> {
        switch self {
        case .blackIron: 1...10
        case .bronze: 11...20
        case .silver: 21...30
        case .gold: 31...50
        case .platinum: 51...75
        case .diamond: 76...100
        case .ruby: 101...250
        case .obsidian: 251...Int.max
        }
    }

    /// The band's width in legs — Obsidian, the ceiling, has none.
    var legsInBand: Int { self == .obsidian ? Int.max : legBand.upperBound - legBand.lowerBound + 1 }

    /// The band's width converted to km at the average leg length — the
    /// budget that resets to zero every time a rank-up happens.
    var kmBudget: Int { legsInBand == Int.max ? Int.max : legsInBand * Self.averageKmPerLeg }

    var next: MilestoneTier? {
        let ordered = Self.allCases.sorted()
        guard let i = ordered.firstIndex(of: self), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    var nameCN: String {
        switch self {
        case .blackIron: "黑鐵"
        case .bronze: "青銅"
        case .silver: "白銀"
        case .gold: "黃金"
        case .platinum: "白金"
        case .diamond: "鑽石"
        case .ruby: "紅寶石"
        case .obsidian: "黑曜石"
        }
    }

    var tagline: String {
        switch self {
        case .blackIron: "旅程的起點"
        case .bronze: "常客初現"
        case .silver: "銀翼行者"
        case .gold: "黃金旅人"
        case .platinum: "白金巡航者"
        case .diamond: "鑽石級旅人"
        case .ruby: "紅寶石飛行家"
        case .obsidian: "黑曜傳奇"
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
        case .obsidian: "obsidian"
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
        case .obsidian: [Color(red: 0.23, green: 0.14, blue: 0.31), Color(red: 0.02, green: 0.02, blue: 0.04)]
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
        case .obsidian: Color(red: 0.48, green: 0.31, blue: 0.68)
        }
    }
}

/// Where a traveller actually stands: the tier reached after walking every
/// completed flight in order, and — since a tier's own budget resets on
/// rank-up while the lifetime leg count keeps climbing — how many legs and
/// how many km have counted toward the CURRENT tier so far.
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
