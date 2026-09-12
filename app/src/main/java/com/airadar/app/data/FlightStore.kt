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
 * In-memory source of truth shared by the trip list and the mailbox importer.
 * Swap this for a database once trips need to survive a restart.
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

    // Server writes go out from here, off the main thread, one after another.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val synced: Boolean get() = AuthStore.isSignedIn

    init {
        reseed()
    }

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

    fun reseed() {
        val today = LocalDate.now()

        val upcoming = listOfNotNull(
            FlightDatabase.lookup("CX392", today.plusDays(2)),
            FlightDatabase.lookup("OZ372", today.plusDays(9)),
            FlightDatabase.lookup("CA826", today.plusDays(24))
        )

        val past = listOfNotNull(
            FlightDatabase.lookup("JL802", today.minusDays(18)),
            FlightDatabase.lookup("MM28", today.minusDays(45))?.copy(
                status = FlightStatus.DELAYED,
                delayMinutes = 45
            ),
            FlightDatabase.lookup("SQ862", today.minusDays(76)),
            FlightDatabase.lookup("NH880", today.minusDays(120)),
            FlightDatabase.lookup("TG607", today.minusDays(150))
        )

        val airborne = listOfNotNull(inFlightSample())

        // Keep anything the traveller added or imported, carry fetched tracks across
        // so a refresh does not throw away a downloaded path, and leave deleted trips
        // deleted.
        val kept = all.filter { it.isPending }
        val tracked = all.filter { it.track != null }.associateBy { it.id }
        val binned = all.filter { it.deletedAt != null }.associateBy { it.id }
        val fresh = (kept + airborne + upcoming + past)
            .distinctBy { it.id }
            .map { f -> tracked[f.id]?.let { f.copy(track = it.track, trackFlownOn = it.trackFlownOn) } ?: f }
            .map { f -> binned[f.id]?.let { f.copy(deletedAt = it.deletedAt) } ?: f }
        publish(fresh + binned.values.filter { b -> fresh.none { it.id == b.id } })
    }

    fun add(flight: Flight) {
        val same = all.firstOrNull { it.flightNumber == flight.flightNumber && it.departureTime == flight.departureTime }
        when {
            same == null -> {
                publish(all + flight)
                push { BackendClient.putTrip(flight) }
            }
            // Adding a trip that sits in the bin brings it back rather than duplicating it.
            same.deletedAt != null -> restore(same.id)
        }
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

    /**
     * A flight that is airborne right now regardless of the device's own zone, so
     * the "Now" section has something to show.
     */
    private fun inFlightSample(): Flight? {
        val from = FlightDatabase.airport("SIN") ?: return null
        val to = FlightDatabase.airport("HKG") ?: return null
        val now = Instant.now()
        return Flight(
            id = "airborne-sample",
            flightNumber = "SQ862",
            airlineName = "Singapore Airlines",
            departure = from.iata,
            arrival = to.iata,
            departureTerminal = "3",
            arrivalTerminal = "1",
            departureTime = now.minus(105, ChronoUnit.MINUTES).atZone(from.zone).toLocalDateTime(),
            arrivalTime = now.plus(135, ChronoUnit.MINUTES).atZone(to.zone).toLocalDateTime(),
            status = FlightStatus.IN_FLIGHT,
            aircraft = "Airbus A350",
            baggageClaim = "6",
            callsign = "SIA862"
        )
    }
}
