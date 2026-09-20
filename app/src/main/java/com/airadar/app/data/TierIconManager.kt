package com.airadar.app.data

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * The Home Screen icon follows the traveller's tier -- called whenever
 * [FlightStore]'s own [FlightStore.tierStanding] changes. Android has no
 * single-call equivalent to iOS's `setAlternateIconName`: each tier above
 * Black Iron gets its own `<activity-alias>` in the manifest (all disabled
 * by default, all pointing at the same MainActivity, each with its own
 * icon), and this just flips exactly one of them on while disabling the
 * rest -- Black Iron itself needs none enabled, since the plain
 * `MainActivity`/`ic_launcher` combination already is Black Iron's icon.
 */
object TierIconManager {

    private const val PACKAGE = "com.airadar.app"

    private val aliasByTier: Map<MilestoneTier, String> = mapOf(
        MilestoneTier.BRONZE to "$PACKAGE.TierIconBronze",
        MilestoneTier.SILVER to "$PACKAGE.TierIconSilver",
        MilestoneTier.GOLD to "$PACKAGE.TierIconGold",
        MilestoneTier.PLATINUM to "$PACKAGE.TierIconPlatinum",
        MilestoneTier.DIAMOND to "$PACKAGE.TierIconDiamond",
        MilestoneTier.RUBY to "$PACKAGE.TierIconRuby",
        MilestoneTier.AMBER to "$PACKAGE.TierIconAmber",
        MilestoneTier.SILK to "$PACKAGE.TierIconSilk",
        MilestoneTier.PORCELAIN to "$PACKAGE.TierIconPorcelain"
    )

    private var lastApplied: MilestoneTier? = null

    /** A no-op call whenever [tier] hasn't actually changed since the last
     * call -- cheap to call on every recomposition of whatever observes
     * tierStanding, the same way iOS's own AppIconManager guards itself. */
    fun apply(context: Context, tier: MilestoneTier) {
        if (lastApplied == tier) return
        val pm = context.applicationContext.packageManager
        val toEnable = aliasByTier[tier]
        for ((_, alias) in aliasByTier) {
            setEnabled(pm, alias, alias == toEnable)
        }
        lastApplied = tier
    }

    private fun setEnabled(pm: PackageManager, alias: String, enabled: Boolean) {
        val state = if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        runCatching {
            pm.setComponentEnabledSetting(ComponentName(PACKAGE, alias), state, PackageManager.DONT_KILL_APP)
        }
    }
}
