package com.airadar.app.data

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.temporal.ChronoUnit

/**
 * In-memory source of truth shared by the trip list and the importers. Signed in,
 * it mirrors the account on the server; signed out, it holds only this session's
 * additions and starts empty.
 */
object FlightStore {

    /** How long a deleted trip waits in the recycle bin before it is gone for good. */
    const val RETENTION_DAYS = 30L

    // Everything, deleted trips included; the two LiveData below are its two halves.
    private var all: List<Flight> = emptyList()

    private val _flights = MutableLiveData<List<Flight>>(emptyList())
    val flights: LiveData<List<Flight>> = _flights

    private val _deleted = MutableLiveData<List<Flight>>(emptyList())
    val deleted: LiveData<List<Flight>> = _deleted

    /** The last plan refusal, for the UI to explain and offer an upgrade. */
    private val _limitHit = MutableLiveData<LimitReached?>(null)
    val limitHit: LiveData<LimitReached?> = _limitHit

    fun clearLimitHit() {
        _limitHit.value = null
    }

    /** Every leg actually flown (or in the air right now) -- what the
     * milestone tiers count against. The same filter My's own map uses for
     * its route network, kept in one place so the two never drift apart. */
    val completedFlights: List<Flight>
        get() = (_flights.value ?: emptyList()).filter {
            (it.phase == FlightPhase.PAST || it.phase == FlightPhase.IN_PROGRESS) && !it.isPending
        }

    /** Where the tier ladder puts this traveller right now. */
    val tierStanding: TierStanding get() = TierStanding.compute(completedFlights)

    /** Rainbow's sequence number, once claimed -- "the Nth traveller here".
     * Never set locally: only the backend hands one out, and only once
     * standing genuinely reads Rainbow. */
    private val _rainbowRank = MutableLiveData<Int?>(null)
    val rainbowRank: LiveData<Int?> = _rainbowRank

    /** Safe to call any time standing is checked: an existing claim just
     * comes back unchanged, so there's no harm calling this opportunistically. */
    fun refreshRainbowRank() {
        if (tierStanding.tier != MilestoneTier.RAINBOW || !synced) return
        scope.launch {
            val rank = runCatching { BackendClient.claimRainbow() }.getOrNull()
            withContext(Dispatchers.Main) { _rainbowRank.value = rank }
        }
    }

    // Server writes go out from here, off the main thread, one after another.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val synced: Boolean get() = AuthStore.isSignedIn


    /** Pull-to-refresh: the account's trips when signed in, the demo set otherwise. */
    suspend fun refresh() {
        if (synced) syncFromServer() else reseed()
    }

    /**
     * Replaces everything with what the account holds. Called at sign-in and on
     * refresh; the demo trips shown while signed out are not carried over.
     */
    suspend fun syncFromServer() {
        val outgoing = runCatching { BackendClient.outgoingShares() }.getOrDefault(emptyMap())
        val live = BackendClient.listTrips().map { it.copy(shares = outgoing[it.id].orEmpty()) }
        val binned = BackendClient.listTrips(deleted = true)
        val incoming = runCatching { BackendClient.incomingShares() }.getOrDefault(emptyList())
        // A trip taken "together" is mine now (the server copied it); the friend's
        // name rides on my copy instead of a second card.
        val together = incoming.filter { it.sharedBy?.status == ShareStatus.TOGETHER }
        val mine = live.map { own ->
            together.firstOrNull { it.flightNumber == own.flightNumber && it.departureTime == own.departureTime }
                ?.let { own.copy(sharedBy = it.sharedBy) } ?: own
        }
        val rest = incoming.filterNot { inc ->
            inc.sharedBy?.status == ShareStatus.TOGETHER &&
                    live.any { it.flightNumber == inc.flightNumber && it.departureTime == inc.departureTime }
        }
        withContext(Dispatchers.Main) { publish(mine + binned + rest) }
    }

    /** Accept, reject or take together a friend's trip; the list is then refreshed. */
    suspend fun respondToShare(flight: Flight, action: String) {
        val share = flight.sharedBy ?: return
        BackendClient.respondToShare(share.id, action)
        syncFromServer()
    }

    /** Shares one of my trips with a friend and shows the new block straight away. */
    suspend fun shareWith(flight: Flight, person: Person) {
        val (share, _) = BackendClient.shareTrip(flight.id, person.id)
        if (share != null) {
            withContext(Dispatchers.Main) {
                publish(all.map { f ->
                    if (f.id == flight.id) f.copy(shares = (f.shares.filterNot { it.person.id == person.id } + share)) else f
                })
            }
        }
    }

    /** Back to the signed-out demo list. */
    fun onSignedOut() {
        all = emptyList()
        reseed()
    }

    private fun push(block: suspend () -> Unit) {
        if (!synced) return
        scope.launch { runCatching { block() } }
    }

    /**
     * Signed out, the list is whatever the traveller added on this phone — the
     * app starts empty. A refresh re-publishes it (recomputing typical durations
     * and dropping expired bin entries) and nothing more.
     */
    fun reseed() {
        publish(all)
    }

    /** Adds a trip; returns false (and records why) when the plan does not allow it. */
    fun add(flight: Flight): Boolean {
        val same = all.firstOrNull { it.flightNumber == flight.flightNumber && it.departureTime == flight.departureTime }
        if (same == null) {
            try {
                Entitlements.checkAdd(flight, all)
            } catch (e: LimitReached) {
                _limitHit.value = e
                return false
            }
        }
        when {
            same == null -> {
                publish(all + flight)
                push {
                    try {
                        BackendClient.putTrip(flight)
                    } catch (e: BackendClient.BackendException) {
                        // The server's count is the truth; take the trip back out.
                        if (e.code == 402) withContext(Dispatchers.Main) {
                            publish(all.filterNot { it.id == flight.id })
                            _limitHit.value = LimitReached(e.message ?: "Plan limit reached.", Entitlements.membership.tier)
                        } else throw e
                    }
                }
            }
            // Adding a trip that sits in the bin brings it back rather than duplicating it.
            same.deletedAt != null -> restore(same.id)
        }
        return true
    }

    fun confirm(flight: Flight) {
        val confirmed = flight.copy(isPending = false)
        publish(all.map { if (it.id == flight.id) confirmed else it })
        push { BackendClient.putTrip(confirmed) }
    }

    fun replace(old: Flight, replacement: Flight) {
        val confirmed = replacement.copy(isPending = false)
        publish(all.filterNot { it.id == old.id } + confirmed)
        push {
            if (old.id != confirmed.id) BackendClient.deleteTrip(old.id)
            BackendClient.putTrip(confirmed)
        }
    }

    /** Moves the trip to the recycle bin; [restore] undoes it within [RETENTION_DAYS]. */
    fun delete(flightId: String) {
        val target = all.firstOrNull { it.id == flightId }
        // A friend's trip has no bin: swiping it away is declining the share.
        // (A trip taken together is my own copy and goes to the bin like any other.)
        target?.sharedBy?.takeIf { flightId.startsWith("shared:") }?.let { share ->
            publish(all.filterNot { it.id == flightId })
            push { BackendClient.respondToShare(share.id, "reject") }
            return
        }
        publish(all.map { if (it.id == flightId) it.copy(deletedAt = Instant.now()) else it })
        push { BackendClient.deleteTrip(flightId) }
    }

    fun restore(flightId: String) {
        publish(all.map { if (it.id == flightId) it.copy(deletedAt = null) else it })
        push { BackendClient.restoreTrip(flightId) }
    }

    fun setTrack(flightId: String, points: List<TrackPoint>, flownOn: LocalDate) {
        publish(all.map { if (it.id == flightId) it.copy(track = points, trackFlownOn = flownOn) else it })
        all.firstOrNull { it.id == flightId }?.let { updated -> push { BackendClient.putTrip(updated) } }
    }

    private fun publish(list: List<Flight>) {
        val expiry = Instant.now().minus(RETENTION_DAYS, ChronoUnit.DAYS)
        val live = list.filter { it.deletedAt == null }
        // Typical durations are averaged over live trips only.
        all = list
            .filterNot { it.deletedAt?.isBefore(expiry) == true }
            .map { it.copy(typicalDurationMinutes = typicalDuration(it, live)) }
        _flights.value = all.filter { it.deletedAt == null }.sortedBy { it.departureInstant ?: Instant.MAX }
        _deleted.value = all.filter { it.deletedAt != null }.sortedByDescending { it.deletedAt }
    }

    /**
     * Average block time over the last week of the same flight number, falling back
     * to the scheduled duration when there is nothing recent to average.
     */
    private fun typicalDuration(flight: Flight, pool: List<Flight>): Int {
        val cutoff = Instant.now().minus(7, ChronoUnit.DAYS)
        val recent = pool.filter {
            it.flightNumber == flight.flightNumber &&
                    it.phase == FlightPhase.PAST &&
                    (it.departureInstant ?: Instant.MIN).isAfter(cutoff)
        }
        return if (recent.isEmpty()) flight.durationMinutes
        else recent.sumOf { it.durationMinutes + it.delayMinutes } / recent.size
    }
}
