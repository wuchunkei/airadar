import UIKit

/// The Home Screen icon follows the traveller's tier — called whenever
/// FlightStore's own tierStanding changes. `setAlternateIconName` needs no
/// special entitlement and no paid Developer Program membership (unlike
/// Wallet or push): it's been a plain public API since iOS 10.3, and
/// switches silently — no confirmation dialog blocks it.
///
/// A traveller can also pick an already-unlocked tier's icon by hand from
/// Settings (`AppIconSettingsView`) — once they do, that choice sticks
/// (`apply` below stops moving the icon on its own) until they either pick
/// a different one or choose "Automatic" again.
@MainActor
enum AppIconManager {
    private static let overrideKey = "AppIconManager.manualOverride"

    /// Called whenever tierStanding changes. A no-op once the traveller has
    /// picked an icon by hand — see `setManual`.
    static func apply(_ tier: MilestoneTier) {
        guard manualOverride == nil else { return }
        setIcon(for: tier)
    }

    /// From the Settings picker: `nil` means Default (Black Iron's icon,
    /// always unlocked); any other tier must already be reached, which the
    /// picker itself is responsible for checking before ever offering it.
    static func setManual(_ tier: MilestoneTier?) {
        UserDefaults.standard.set(tier?.artKey ?? "default", forKey: overrideKey)
        setIcon(for: tier)
    }

    /// Back to following the tier ladder automatically — applied at once so
    /// the icon doesn't wait for the next natural tierStanding change.
    static func resetToAutomatic(currentTier: MilestoneTier) {
        UserDefaults.standard.removeObject(forKey: overrideKey)
        setIcon(for: currentTier)
    }

    /// The manually-picked tier, if any -- `nil` here means Default was
    /// itself the manual pick, so it's returned as `.some(nil)` via the
    /// outer Optional; plain `nil` means no manual pick exists at all
    /// (still automatic). Kept private: everything outside this file asks
    /// through `isManual`/`manualTierArtKey` instead of parsing the raw key.
    private static var manualOverride: String?? {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey) else { return nil }
        return .some(raw == "default" ? nil : raw)
    }

    /// Whether Settings should show "Automatic" as unchecked and some
    /// specific icon as checked instead.
    static var isManual: Bool { manualOverride != nil }

    /// The manually-picked tier's art key, or nil for Default (or for no
    /// manual pick at all — `isManual` disambiguates that case).
    static var manualArtKey: String? { manualOverride ?? nil }

    private static func setIcon(for tier: MilestoneTier?) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        // Black Iron is the default icon that ships in the bundle, not a
        // registered alternate — reaching it again means reverting to nil.
        let name: String? = (tier == nil || tier == .blackIron) ? nil : tier?.artKey
        guard UIApplication.shared.alternateIconName != name else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            if let error { print("AppIconManager: couldn't switch to \(name ?? "the default icon"): \(error.localizedDescription)") }
        }
    }
}
