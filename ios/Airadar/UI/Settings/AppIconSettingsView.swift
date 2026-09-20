import SwiftUI

/// Choose the Home Screen icon by hand -- every tier is shown, so the whole
/// ladder reads as a roadmap, but only Default and whatever the traveller
/// has actually reached are tappable; anything further up sits locked,
/// dimmed, with no way to jump ahead. Picking one sticks until "Automatic"
/// is picked again, which hands the icon back to following the tier ladder
/// on its own (`AppIconManager`).
struct AppIconSettingsView: View {
    @EnvironmentObject private var store: FlightStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var manual = AppIconManager.isManual
    @State private var manualArtKey = AppIconManager.manualArtKey

    private var reached: MilestoneTier { store.tierStanding.tier }
    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Button(action: goAutomatic) {
                    HStack(spacing: 14) {
                        icon(for: reached, dimmed: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Automatic").font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text("Follows your tier — \(reached.name) right now").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !manual { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).font(.title3) }
                    }
                    .padding(14)
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Every tier").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    LazyVGrid(columns: columns, spacing: 18) {
                        cell(tier: .blackIron, title: "Default", locked: false)
                        ForEach(MilestoneTier.allCases.filter { $0 != .blackIron }, id: \.rawValue) { tier in
                            cell(tier: tier, title: tier.name, locked: tier > reached)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("App Icon")
    }

    private func goAutomatic() {
        AppIconManager.resetToAutomatic(currentTier: reached)
        manual = false; manualArtKey = nil
    }

    private func pick(_ tier: MilestoneTier) {
        AppIconManager.setManual(tier == .blackIron ? nil : tier)
        manual = true; manualArtKey = tier == .blackIron ? nil : tier.artKey
    }

    private func cell(tier: MilestoneTier, title: String, locked: Bool) -> some View {
        let selected = manual && manualArtKey == (tier == .blackIron ? nil : tier.artKey)
        return Button {
            if !locked { pick(tier) }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    icon(for: tier, dimmed: locked)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            }
                        }
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
                Text(title).font(.caption2).foregroundStyle(locked ? .tertiary : .secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }

    private func icon(for tier: MilestoneTier, dimmed: Bool) -> some View {
        let bg = colorScheme == .dark ? Color(red: 0.08, green: 0.086, blue: 0.098) : Color(red: 0.882, green: 0.890, blue: 0.910)
        return RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(bg)
            .overlay {
                if tier == .blackIron {
                    DefaultGlyph(dark: colorScheme == .dark).frame(width: 38, height: 38)
                } else {
                    TierBadgeView(tier: tier, size: 44)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.38 : 1)
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
