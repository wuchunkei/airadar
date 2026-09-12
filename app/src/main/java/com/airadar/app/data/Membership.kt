package com.airadar.app.data

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.LocalDate
import java.time.temporal.ChronoUnit

enum class Tier { GUEST, SUPERIOR, PREMIUM }

/** What a tier allows; null means no limit. Mirrors billing.py on the server. */
@Immutable
data class Limits(
    val maxPastTrips: Int?,
    val futureDays: Int?,
    val maxTrips: Int?,
    val historyLookup: Boolean,
    val sharing: Boolean
) {
    companion object {
        val GUEST = Limits(maxPastTrips = 1, futureDays = 7, maxTrips = 3, historyLookup = false, sharing = false)
        val SUPERIOR = Limits(maxPastTrips = 5, futureDays = 30, maxTrips = null, historyLookup = false, sharing = true)
        val PREMIUM = Limits(maxPastTrips = null, futureDays = null, maxTrips = null, historyLookup = true, sharing = true)
        fun of(tier: Tier) = when (tier) {
            Tier.GUEST -> GUEST
            Tier.SUPERIOR -> SUPERIOR
            Tier.PREMIUM -> PREMIUM
        }
    }
}

@Immutable
data class Membership(
    val tier: Tier,
    val until: Instant?,
    val trial: Boolean
) {
    val limits: Limits get() = Limits.of(tier)

    companion object {
        val GUEST = Membership(Tier.GUEST, null, false)
    }
}

/** Play Store subscription products, as created in the Play Console. */
object Plans {
    const val SUPERIOR = "superior_monthly"
    const val PREMIUM = "premium_monthly"
    const val SUPERIOR_PRICE = "US$1 / month"
    const val PREMIUM_PRICE = "US$5 / month"
}

/** Why a trip could not be added under the current plan, and what would allow it. */
class LimitReached(val reason: String, val tier: Tier) : Exception(reason)

/**
 * The client-side gate. Signed out it is the only gate; signed in the server
 * enforces the same rules, and this just saves a round trip and a 402.
 */
object Entitlements {

    val membership: Membership
        get() = if (AuthStore.isSignedIn) AuthStore.user.value?.membership ?: Membership.GUEST else Membership.GUEST

    /** Throws [LimitReached] when [flight] would exceed the plan, given what is already kept. */
    fun checkAdd(flight: Flight, existing: List<Flight>) {
        val m = membership
        val lim = m.limits
        val live = existing.filter { it.deletedAt == null && it.sharedBy == null }
        if (live.any { it.id == flight.id }) return
        val today = LocalDate.now()
        val day = flight.departureTime.toLocalDate()
        val past = live.count { it.departureTime.toLocalDate() < today }

        lim.maxTrips?.let { if (live.size >= it) throw LimitReached("$it trips is the most this plan keeps.", m.tier) }
        if (day < today) lim.maxPastTrips?.let {
            if (past >= it) throw LimitReached("This plan keeps $it past trip${if (it == 1) "" else "s"}.", m.tier)
        }
        if (day > today) lim.futureDays?.let {
            if (ChronoUnit.DAYS.between(today, day) > it) throw LimitReached("This plan adds trips up to $it days ahead.", m.tier)
        }
    }
}
