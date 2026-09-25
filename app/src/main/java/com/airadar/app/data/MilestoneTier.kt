package com.airadar.app.data

import androidx.compose.ui.graphics.Color
import java.time.Instant

/**
 * The nine visible tiers, plus one hidden one above them — run the way a
 * real airline's elite tiers are: promotion happens on legs flown OR
 * distance flown SINCE THE LAST RANK-UP, whichever gets there first, and
 * both counters reset to zero the moment that happens — a long-haul
 * traveller and a short-hop commuter both climb, just by different
 * arithmetic, and neither a single mega-flight nor a burst of short hops
 * vaults more than one tier at a time. (The lifetime flight total shown
 * elsewhere — My's own stats panel — is a separate, never-reset count; it
 * just isn't what decides a rank-up.)
 *
 * Porcelain (751+ legs) is a secret: nothing before it hints it exists, and
 * reaching it is rare enough that it also carries a sequence number — the
 * Nth traveller ever to get there — awarded by the backend, never the
 * client ([BackendClient.claimPorcelain]). It's the true ceiling this ladder
 * used to call Rainbow -- renamed, and split off from what used to be one
 * enormous top band (Obsidian, then Rainbow) into three narrower ones
 * (Amber, Silk, Porcelain).
 *
 * Declared in ladder order -- Kotlin enums compare by declaration (ordinal)
 * order, matching iOS's own `rawValue` ordering, so `<`/`compareTo` need no
 * extra code here.
 */
enum class MilestoneTier {
    BLACK_IRON, BRONZE, SILVER, GOLD, PLATINUM, DIAMOND, RUBY, AMBER, SILK, PORCELAIN;

    /** The lifetime leg-count band this tier owns -- legs 1-10 are Black
     * Iron, 11-20 Bronze, and so on, however a traveller actually gets
     * there (some ranks up early on distance, see [TierStanding.compute]). */
    val legBand: IntRange
        get() = when (this) {
            BLACK_IRON -> 1..10
            BRONZE -> 11..20
            SILVER -> 21..30
            GOLD -> 31..50
            PLATINUM -> 51..75
            DIAMOND -> 76..100
            RUBY -> 101..250
            AMBER -> 251..450
            SILK -> 451..750
            PORCELAIN -> 751..Int.MAX_VALUE
        }

    /** The band's width in legs -- Porcelain, the true ceiling, has none. */
    val legsInBand: Int get() = if (this == PORCELAIN) Int.MAX_VALUE else legBand.last - legBand.first + 1

    /** The band's width converted to km at the average leg length -- the
     * budget that resets to zero every time a rank-up happens. */
    val kmBudget: Int get() = if (legsInBand == Int.MAX_VALUE) Int.MAX_VALUE else legsInBand * AVERAGE_KM_PER_LEG

    val next: MilestoneTier?
        get() {
            val ordered = entries
            val i = ordered.indexOf(this)
            return ordered.getOrNull(i + 1)
        }

    /** English for now, matching the rest of the app -- the Chinese names
     * (黑鐵/青銅/白銀/黃金/白金/鑽石/紅寶石/黑曜石/彩虹) wait for the real
     * localization pass. */
    val displayName: String
        get() = when (this) {
            BLACK_IRON -> tr("Black Iron")
            BRONZE -> tr("Bronze")
            SILVER -> tr("Silver")
            GOLD -> tr("Gold")
            PLATINUM -> tr("Platinum")
            DIAMOND -> tr("Diamond")
            RUBY -> tr("Ruby")
            AMBER -> tr("Amber")
            SILK -> tr("Silk")
            PORCELAIN -> tr("Porcelain")
        }

    /** Only ever shown for the tier with no next -- today just Porcelain. */
    val tagline: String
        get() = when (this) {
            BLACK_IRON -> tr("Every journey starts here.")
            BRONZE -> tr("Ten flights and counting.")
            SILVER -> tr("A quarter-century in the air.")
            GOLD -> tr("Fifty flights strong.")
            PLATINUM -> tr("Triple digits — a real habit now.")
            DIAMOND -> tr("Diamond-clear dedication.")
            RUBY -> tr("Two-fifty, and still climbing.")
            AMBER -> tr("Preserved in flight, one leg at a time.")
            SILK -> tr("Smooth as the old trade routes.")
            PORCELAIN -> tr("A secret worth finding.")
        }

    /** The real artwork's file key -- `tier_<key>_logo` under
     * `res/drawable-nodpi`. Placeholder gradients only kick in if a
     * drawable is ever missing (a tier added here before its art arrives, say). */
    val artKey: String
        get() = when (this) {
            BLACK_IRON -> "blackiron"
            BRONZE -> "bronze"
            SILVER -> "silver"
            GOLD -> "gold"
            PLATINUM -> "platinum"
            DIAMOND -> "diamond"
            RUBY -> "ruby"
            AMBER -> "amber"
            SILK -> "silk"
            PORCELAIN -> "porcelain"
        }

    /** Placeholder centre -> edge palette -- only ever seen if [artKey]'s
     * drawable is missing from resources. */
    val gradient: List<Color>
        get() = when (this) {
            BLACK_IRON -> listOf(Color(0xFF3E4045), Color(0xFF17181C))
            BRONZE -> listOf(Color(0xFFE1A978), Color(0xFF8A4A2B))
            SILVER -> listOf(Color(0xFFF5F5F7), Color(0xFF9EA3AB))
            GOLD -> listOf(Color(0xFFFFF2B0), Color(0xFFCA941A))
            PLATINUM -> listOf(Color(0xFFEDF2F7), Color(0xFFA8B8C4))
            DIAMOND -> listOf(Color(0xFFEBFDFF), Color(0xFF5EBFE0))
            RUBY -> listOf(Color(0xFFFF8A8A), Color(0xFF7A0D1F))
            AMBER -> listOf(Color(0xFFFFD166), Color(0xFFB86B0D))
            SILK -> listOf(Color(0xFFFAE6DB), Color(0xFFCCA093))
            PORCELAIN -> listOf(Color(0xFFFAFCFF), Color(0xFF8CA6D1))
        }

    val rimColor: Color
        get() = when (this) {
            BLACK_IRON -> Color(0xFF5C6169)
            BRONZE -> Color(0xFFC97A3D)
            SILVER -> Color(0xFFC9CBD0)
            GOLD -> Color(0xFFF2C94D)
            PLATINUM -> Color(0xFFCFE1EC)
            DIAMOND -> Color(0xFFBCF0FF)
            RUBY -> Color(0xFFD91F40)
            AMBER -> Color(0xFFE08F1A)
            SILK -> Color(0xFFE6BFB3)
            PORCELAIN -> Color(0xFF4D6BAD)
        }

    companion object {
        /** The average distance of a leg, used to convert a tier's leg-width
         * into an equivalent km budget -- the traveller's own figure. */
        const val AVERAGE_KM_PER_LEG = 1157
    }
}

/**
 * Where a traveller actually stands: the tier reached after walking every
 * completed flight in order, and how many legs and how many km have
 * counted toward the CURRENT tier so far -- both reset to zero at every
 * rank-up, which is what makes "legs or km, whichever first" a real race
 * tier by tier instead of a one-time fuse.
 */
data class TierStanding(val tier: MilestoneTier, val legsIntoTier: Int, val kmIntoTier: Int) {

    val legsToNext: Int? get() = tier.next?.let { (tier.legsInBand - legsIntoTier).coerceAtLeast(0) }
    val kmToNext: Int? get() = tier.next?.let { (tier.kmBudget - kmIntoTier).coerceAtLeast(0) }

    companion object {
        /** Every completed flight, oldest first, feeds both counters;
         * whichever hits the current tier's budget first promotes -- same
         * as an airline combining segments and miles toward the same rank-up. */
        fun compute(flights: List<Flight>): TierStanding {
            val ordered = flights.sortedBy { it.departureInstant ?: Instant.MIN }
            var tier = MilestoneTier.BLACK_IRON
            var legs = 0
            var km = 0
            for (f in ordered) {
                legs += 1
                km += f.distanceKm
                while (true) {
                    val next = tier.next ?: break
                    if (legs >= tier.legsInBand || km >= tier.kmBudget) {
                        tier = next
                        legs = 0; km = 0
                    } else break
                }
            }
            return TierStanding(tier, legs, km)
        }
    }
}

/** A plain linear blend toward [other] -- used to fade the route-progress
 * plane and its flown line from one tier's colour into the next's as it
 * moves along, rather than snapping from one to the other. */
fun Color.mixed(with: Color, fraction: Float): Color {
    val f = fraction.coerceIn(0f, 1f)
    return Color(
        red = red + (with.red - red) * f,
        green = green + (with.green - green) * f,
        blue = blue + (with.blue - blue) * f,
        alpha = alpha + (with.alpha - alpha) * f
    )
}
