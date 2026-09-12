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
    /** Trips in the air or ahead — Now and Coming together. */
    val maxUpcomingTrips: Int?,
    val maxTrips: Int?,
    val futureDays: Int?,
    val sharing: Boolean
) {
    companion object {
        val GUEST = Limits(maxPastTrips = 1, maxUpcomingTrips = null, maxTrips = 3, futureDays = 7, sharing = false)
        val SUPERIOR = Limits(maxPastTrips = 5, maxUpcomingTrips = 10, maxTrips = null, futureDays = 30, sharing = true)
        val PREMIUM = Limits(maxPastTrips = null, maxUpcomingTrips = null, maxTrips = null, futureDays = null, sharing = true)
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
    val grace: Boolean = false,
    val token: String? = null
) {
    val limits: Limits get() = Limits.of(tier)

    companion object {
        val GUEST = Membership(Tier.GUEST, null)
    }
}

/** A token the traveller entered and the server accepted for this phone — before or without sign-in. */
@Immutable
data class CheckedToken(val token: String, val tier: Tier, val until: Instant, val boundEmail: String?)

/** Plans are bought on the web (Stripe) and redeemed here with a token. */
object Plans {
    const val SUPERIOR_PRICE = "US$1 / month"
    const val PREMIUM_PRICE = "US$5 / month"
    val payUrl: String get() = com.airadar.app.BuildConfig.BACKEND_URL.trimEnd('/') + "/pay"
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
        if (day >= today) lim.maxUpcomingTrips?.let {
            if (live.size - past >= it) throw LimitReached("This plan keeps $it trips ahead at a time.", m.tier)
        }
        if (day > today) lim.futureDays?.let {
            if (ChronoUnit.DAYS.between(today, day) > it) throw LimitReached("This plan adds trips up to $it days ahead.", m.tier)
        }
    }
}
