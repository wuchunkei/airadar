package com.airadar.app.data

import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
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

    init {
        reseed()
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
            same == null -> publish(all + flight)
            // Adding a trip that sits in the bin brings it back rather than duplicating it.
            same.deletedAt != null -> restore(same.id)
        }
    }

    fun confirm(flight: Flight) {
        publish(all.map { if (it.id == flight.id) it.copy(isPending = false) else it })
    }

    fun replace(old: Flight, replacement: Flight) {
        publish(all.filterNot { it.id == old.id } + replacement.copy(isPending = false))
    }

    /** Moves the trip to the recycle bin; [restore] undoes it within [RETENTION_DAYS]. */
    fun delete(flightId: String) {
        publish(all.map { if (it.id == flightId) it.copy(deletedAt = Instant.now()) else it })
    }

    fun restore(flightId: String) {
        publish(all.map { if (it.id == flightId) it.copy(deletedAt = null) else it })
    }

    fun setTrack(flightId: String, points: List<TrackPoint>, flownOn: LocalDate) {
        publish(all.map { if (it.id == flightId) it.copy(track = points, trackFlownOn = flownOn) else it })
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
