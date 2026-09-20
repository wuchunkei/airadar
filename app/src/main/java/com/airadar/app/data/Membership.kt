package com.airadar.app.data

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.LocalDate
import java.time.temporal.ChronoUnit

enum class Tier { GUEST, PREMIUM }

/** What a tier allows; null means no limit. Mirrors billing.py on the server. */
@Immutable
data class Limits(
    /** Trips in the air or ahead — Now and Coming together. */
    val maxUpcomingTrips: Int?,
    /** How far back a past trip may be added, or kept appearing once synced. */
    val pastDays: Int?,
    val futureDays: Int?
) {
    companion object {
        val GUEST = Limits(maxUpcomingTrips = 1, pastDays = 7, futureDays = null)
        val PREMIUM = Limits(maxUpcomingTrips = null, pastDays = null, futureDays = null)
        fun of(tier: Tier) = when (tier) {
            Tier.GUEST -> GUEST
            Tier.PREMIUM -> PREMIUM
        }
    }
}

@Immutable
data class Membership(
    val tier: Tier,
    val until: Instant?,
    val grace: Boolean = false,
    val token: String? = null,
    /** The Share add-on — its own small subscription, held or not
     * independent of [tier]; a guest can have it, a Premium member might not. */
    val canShare: Boolean = false
) {
    val limits: Limits get() = Limits.of(tier)

    companion object {
        val GUEST = Membership(Tier.GUEST, null)
    }
}

/** A token the traveller entered and the server accepted for this phone — before or without sign-in. */
@Immutable
data class CheckedToken(val token: String, val tier: Tier, val until: Instant?, val boundEmail: String?)

/** Plans are bought on the web (Stripe) and redeemed here with a token. */
object Plans {
    const val PREMIUM_PRICE = "US$5 / month"
    const val PREMIUM_BUYOUT_PRICE = "US$50 once"
    const val SHARE_PRICE = "US$0.99 / month"
    val payUrl: String get() = com.airadar.app.BuildConfig.BACKEND_URL.trimEnd('/') + "/pay"
}

/** Why a trip could not be added under the current plan, and what would allow it. */
class LimitReached(val reason: String, val tier: Tier) : Exception(reason)

/**
 * The client-side gate. Signed out it is the only gate; signed in the server
 * enforces the same rules, and this just saves a round trip and a 402.
 */
object Entitlements {

    /** Off while the token/paywall page is shelved — everyone gets Premium's
     * limits, which is to say none, signed in or not. Flip this back on —
     * and bring back the token entry UI it's paired with — to restore
     * gating behind sign-in + token, or an Apple/Google IAP flow, later;
     * backend/app/billing.py's PAYWALL_ENABLED and iOS's
     * Entitlements.paywallEnabled are the matching switches. */
    const val paywallEnabled = false

    val membership: Membership
        get() {
            if (!paywallEnabled) return Membership(Tier.PREMIUM, null, canShare = true)
            return if (AuthStore.isSignedIn) AuthStore.user.value?.membership ?: Membership.GUEST else Membership.GUEST
        }

    /** Throws [LimitReached] when [flight] would exceed the plan, given what is already kept. */
    fun checkAdd(flight: Flight, existing: List<Flight>) {
        if (!paywallEnabled) return
        val m = membership
        val lim = m.limits
        val live = existing.filter { it.deletedAt == null && it.sharedBy == null }
        if (live.any { it.id == flight.id }) return
        val today = LocalDate.now()
        val day = flight.departureTime.toLocalDate()

        if (day < today) lim.pastDays?.let {
            if (ChronoUnit.DAYS.between(day, today) > it) throw LimitReached("This plan adds past trips up to $it days back.", m.tier)
        }
        if (day > today) lim.futureDays?.let {
            if (ChronoUnit.DAYS.between(today, day) > it) throw LimitReached("This plan adds trips up to $it days ahead.", m.tier)
        }
        if (day >= today) lim.maxUpcomingTrips?.let {
            val upcoming = live.count { f -> f.departureTime.toLocalDate() >= today }
            if (upcoming >= it) throw LimitReached("This plan keeps $it trip${if (it == 1) "" else "s"} ahead at a time.", m.tier)
        }
    }
}
