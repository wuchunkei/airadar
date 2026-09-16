import SwiftUI

/// The ten milestone tiers, named after materials — the free personal-team
/// account this ships under can't get a Wallet Pass Type ID, so this is the
/// in-app stand-in instead: a badge in Trip/Past leading to My, and a
/// progress card on My itself. Placeholder colours below stand in for real
/// artwork (see the Downloads-folder mockups) until that's ready.
enum MilestoneTier: Int, CaseIterable, Comparable {
    case blackIron = 0
    case firstFlight = 1
    case bronze = 10
    case silver = 25
    case gold = 50
    case platinum = 100
    case emerald = 250
    case diamond = 400
    case ruby = 600
    case obsidian = 1000

    static func < (a: MilestoneTier, b: MilestoneTier) -> Bool { a.rawValue < b.rawValue }

    /// The highest tier a flight count has actually reached.
    static func current(for flightCount: Int) -> MilestoneTier {
        allCases.filter { $0.rawValue <= flightCount }.max() ?? .blackIron
    }

    /// The next tier up, or nil once Obsidian is reached.
    var next: MilestoneTier? {
        let ordered = Self.allCases.sorted()
        guard let i = ordered.firstIndex(of: self), i + 1 < ordered.count else { return nil }
        return ordered[i + 1]
    }

    var nameCN: String {
        switch self {
        case .blackIron: "黑鐵"
        case .firstFlight: "首飛"
        case .bronze: "青銅"
        case .silver: "白銀"
        case .gold: "黃金"
        case .platinum: "鉑金"
        case .emerald: "翡翠"
        case .diamond: "鑽石"
        case .ruby: "紅寶石"
        case .obsidian: "黑曜石"
        }
    }

    var tagline: String {
        switch self {
        case .blackIron: "旅程的起點"
        case .firstFlight: "首飛紀念"
        case .bronze: "常客初現"
        case .silver: "銀翼行者"
        case .gold: "黃金旅人"
        case .platinum: "鉑金巡航者"
        case .emerald: "翡翠環球者"
        case .diamond: "鑽石級旅人"
        case .ruby: "紅寶石飛行家"
        case .obsidian: "黑曜傳奇"
        }
    }

    /// Centre → edge, the same two-stop palette the Downloads-folder badge
    /// mockups used.
    var gradient: [Color] {
        switch self {
        case .blackIron: [Color(red: 0.24, green: 0.25, blue: 0.27), Color(red: 0.09, green: 0.09, blue: 0.11)]
        case .firstFlight: [Color(red: 1.00, green: 0.88, blue: 0.70), Color(red: 0.36, green: 0.55, blue: 0.84)]
        case .bronze: [Color(red: 0.88, green: 0.66, blue: 0.47), Color(red: 0.54, green: 0.29, blue: 0.17)]
        case .silver: [Color(red: 0.96, green: 0.96, blue: 0.97), Color(red: 0.62, green: 0.64, blue: 0.67)]
        case .gold: [Color(red: 1.00, green: 0.95, blue: 0.69), Color(red: 0.79, green: 0.58, blue: 0.10)]
        case .platinum: [Color(red: 0.93, green: 0.95, blue: 0.97), Color(red: 0.66, green: 0.72, blue: 0.77)]
        case .emerald: [Color(red: 0.55, green: 0.88, blue: 0.69), Color(red: 0.06, green: 0.42, blue: 0.27)]
        case .diamond: [Color(red: 0.92, green: 0.99, blue: 1.00), Color(red: 0.37, green: 0.75, blue: 0.88)]
        case .ruby: [Color(red: 1.00, green: 0.54, blue: 0.54), Color(red: 0.48, green: 0.05, blue: 0.12)]
        case .obsidian: [Color(red: 0.23, green: 0.14, blue: 0.31), Color(red: 0.02, green: 0.02, blue: 0.04)]
        }
    }

    var rimColor: Color {
        switch self {
        case .blackIron: Color(red: 0.36, green: 0.38, blue: 0.41)
        case .firstFlight: Color(red: 0.96, green: 0.73, blue: 0.26)
        case .bronze: Color(red: 0.79, green: 0.48, blue: 0.24)
        case .silver: Color(red: 0.79, green: 0.80, blue: 0.82)
        case .gold: Color(red: 0.95, green: 0.79, blue: 0.30)
        case .platinum: Color(red: 0.81, green: 0.88, blue: 0.93)
        case .emerald: Color(red: 0.24, green: 0.81, blue: 0.56)
        case .diamond: Color(red: 0.74, green: 0.94, blue: 1.00)
        case .ruby: Color(red: 0.85, green: 0.12, blue: 0.25)
        case .obsidian: Color(red: 0.48, green: 0.31, blue: 0.68)
        }
    }

    /// The icon colour needs to be dark on the pale materials (silver,
    /// platinum, diamond) or it disappears into them.
    var iconColor: Color {
        switch self {
        case .silver, .platinum, .diamond: Color(red: 0.16, green: 0.18, blue: 0.22)
        default: .white
        }
    }
}

/// A small circular medallion — placeholder art (a plain gradient + rim +
/// plane glyph) standing in for real per-tier artwork.
struct TierBadgeView: View {
    let tier: MilestoneTier
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: tier.gradient, center: UnitPoint(x: 0.35, y: 0.32), startRadius: 0, endRadius: size * 0.75))
            Circle().strokeBorder(tier.rimColor, lineWidth: max(1.5, size * 0.07))
            Image(systemName: "airplane")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tier.iconColor)
                .rotationEffect(.degrees(45))
        }
        .frame(width: size, height: size)
    }
}
