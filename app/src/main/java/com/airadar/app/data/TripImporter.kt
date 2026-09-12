package com.airadar.app.data

import java.time.LocalDate

/** A flight number and a date spotted in some text, not yet checked against anything. */
data class Candidate(val flightNumber: String, val date: LocalDate)

/**
 * Turns candidates from email or calendar text into pending trips: each pair is
 * looked up on the server (the timetable knows every airline), duplicates and
 * trips already in the list are dropped, and what survives is added for the
 * traveller to confirm.
 */
object TripImporter {

    /** Returns how many trips were added. */
    suspend fun import(candidates: Collection<Candidate>, onProgress: (done: Int, total: Int) -> Unit = { _, _ -> }): Int {
        val distinct = candidates.distinct()
        val existing = FlightStore.flights.value.orEmpty()
        var added = 0
        distinct.forEachIndexed { index, c ->
            val already = existing.any { it.flightNumber == c.flightNumber && it.departureTime.toLocalDate() == c.date }
            if (!already) {
                resolve(c)?.let {
                    FlightStore.add(it.copy(isPending = true))
                    added++
                }
            }
            onProgress(index + 1, distinct.size)
        }
        return added
    }

    private suspend fun resolve(c: Candidate): Flight? =
        if (BackendClient.isConfigured) {
            runCatching { BackendClient.flight(c.flightNumber, c.date) }.getOrNull()
        } else {
            FlightDatabase.lookup(c.flightNumber, c.date)
        }
}
