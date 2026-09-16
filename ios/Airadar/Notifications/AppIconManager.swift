import UIKit

/// The Home Screen icon follows the traveller's tier — called whenever
/// FlightStore's own tierStanding changes. `setAlternateIconName` needs no
/// special entitlement and no paid Developer Program membership (unlike
/// Wallet or push): it's been a plain public API since iOS 10.3, and
/// switches silently — no confirmation dialog blocks it.
@MainActor
enum AppIconManager {
    static func apply(_ tier: MilestoneTier) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        // Black Iron is the default icon that ships in the bundle, not a
        // registered alternate — reaching it again means reverting to nil.
        let name: String? = tier == .blackIron ? nil : tier.artKey
        guard UIApplication.shared.alternateIconName != name else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            if let error { print("AppIconManager: couldn't switch to \(name ?? "the default icon"): \(error.localizedDescription)") }
        }
    }
}
