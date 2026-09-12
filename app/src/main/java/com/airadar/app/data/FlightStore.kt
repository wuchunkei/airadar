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

    private val _flights = MutableLiveData<List<Flight>>(emptyList())
    val flights: LiveData<List<Flight>> = _flights

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

        // Keep anything the traveller added or imported, and carry fetched tracks
        // across so a refresh does not throw away a downloaded path.
        val current = _flights.value.orEmpty()
        val kept = current.filter { it.isPending }
        val tracked = current.filter { it.track != null }.associateBy { it.id }
        publish((kept + airborne + upcoming + past).map { fresh ->
            tracked[fresh.id]?.let { fresh.copy(track = it.track, trackFlownOn = it.trackFlownOn) } ?: fresh
        })
    }

    fun add(flight: Flight) {
        val existing = _flights.value.orEmpty()
        if (existing.any { it.flightNumber == flight.flightNumber && it.departureTime == flight.departureTime }) return
        publish(existing + flight)
    }

    fun confirm(flight: Flight) {
        publish(_flights.value.orEmpty().map {
            if (it.id == flight.id) it.copy(isPending = false) else it
        })
    }

    fun replace(old: Flight, replacement: Flight) {
        val without = _flights.value.orEmpty().filterNot { it.id == old.id }
        publish(without + replacement.copy(isPending = false))
    }

    fun remove(flight: Flight) {
        publish(_flights.value.orEmpty().filterNot { it.id == flight.id })
    }

    fun setTrack(flightId: String, points: List<TrackPoint>, flownOn: LocalDate) {
        publish(_flights.value.orEmpty().map {
            if (it.id == flightId) it.copy(track = points, trackFlownOn = flownOn) else it
        })
    }

    private fun publish(list: List<Flight>) {
        val withDurations = list.map { it.copy(typicalDurationMinutes = typicalDuration(it, list)) }
        _flights.value = withDurations.sortedBy { it.departureInstant ?: Instant.MAX }
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
