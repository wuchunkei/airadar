import SwiftUI

/// Choose the Home Screen icon by hand -- Default is always here, and each
/// tier above it joins the list the moment the traveller actually reaches
/// it (never before, and never hinting at what's still locked). Picking one
/// sticks until "Automatic" is picked again, which hands the icon back to
/// following the tier ladder on its own (`AppIconManager`).
struct AppIconSettingsView: View {
    @EnvironmentObject private var store: FlightStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var manual = AppIconManager.isManual
    @State private var manualArtKey = AppIconManager.manualArtKey

    private var reached: MilestoneTier { store.tierStanding.tier }
    /// Every tier the traveller has actually reached, ladder order --
    /// Black Iron itself is Default, not a row of its own here.
    private var unlockedTiers: [MilestoneTier] {
        MilestoneTier.allCases.filter { $0 != .blackIron && $0 <= reached }
    }

    var body: some View {
        List {
            Section {
                row(title: "Automatic", subtitle: "Follows your tier — \(reached.name) right now",
                    selected: !manual) {
                    icon(for: reached)
                } action: {
                    AppIconManager.resetToAutomatic(currentTier: reached)
                    manual = false; manualArtKey = nil
                }
            }
            Section {
                row(title: "Default", subtitle: nil, selected: manual && manualArtKey == nil) {
                    icon(for: .blackIron)
                } action: {
                    AppIconManager.setManual(nil)
                    manual = true; manualArtKey = nil
                }
                ForEach(unlockedTiers, id: \.rawValue) { tier in
                    row(title: tier.name, subtitle: nil, selected: manual && manualArtKey == tier.artKey) {
                        icon(for: tier)
                    } action: {
                        AppIconManager.setManual(tier)
                        manual = true; manualArtKey = tier.artKey
                    }
                }
            } footer: {
                if unlockedTiers.count < MilestoneTier.allCases.count - 1 {
                    Text("Reach a new tier to unlock its icon.")
                }
            }
        }
        .navigationTitle("App Icon")
    }

    private func icon(for tier: MilestoneTier) -> some View {
        let bg = colorScheme == .dark ? Color(red: 0.08, green: 0.086, blue: 0.098) : Color(red: 0.882, green: 0.890, blue: 0.910)
        return RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(bg)
            .overlay {
                if tier == .blackIron {
                    DefaultGlyph(dark: colorScheme == .dark).frame(width: 34, height: 34)
                } else {
                    TierBadgeView(tier: tier, size: 40)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func row(title: String, subtitle: String?, selected: Bool,
                      @ViewBuilder icon: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Default's own flat glyph -- a loose bundle resource, same convention as
/// TierBadgeView's tier art, since Home Screen alternate-icon images
/// themselves live sealed in the asset catalog and aren't loadable at
/// runtime for a preview like this.
private struct DefaultGlyph: View {
    let dark: Bool
    private static var cache: [String: UIImage] = [:]
    private var art: UIImage? {
        let key = dark ? "tier-default-dark-logo" : "tier-default-light-logo"
        if let cached = Self.cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: key, withExtension: "png"),
              let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        Self.cache[key] = image
        return image
    }

    var body: some View {
        if let art { Image(uiImage: art).resizable().scaledToFit() }
        else { Image(systemName: "airplane").font(.system(size: 20, weight: .semibold)).foregroundStyle(dark ? .white : .black) }
    }
}
