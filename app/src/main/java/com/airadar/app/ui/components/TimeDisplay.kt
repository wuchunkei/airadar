package com.airadar.app.ui.components

import com.airadar.app.data.Flight
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

/** A clock reading plus the zone tag that goes after it. */
data class ShownTime(val clock: String, val zoneTag: String)

private val clockFormat: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
private val zoneAbbrev: DateTimeFormatter = DateTimeFormatter.ofPattern("z", Locale.ENGLISH)

/**
 * How a departure or arrival should read on screen.
 *
 * Default: the airport's own wall-clock time, tagged with its GMT offset —
 * `07:00 GMT+9`.
 *
 * Forced to the phone's zone: the same instant re-expressed in that zone, tagged
 * with the phone zone's abbreviation and how far ahead or behind the airport
 * really is — a Seoul arrival seen from Hong Kong reads `06:00 HKT(+1)`.
 */
fun Flight.shownTime(
    arrival: Boolean,
    forceSystemZone: Boolean,
    includeDelay: Boolean = false
): ShownTime {
    val airport = if (arrival) arrivalAirport else departureAirport
    val scheduled = if (arrival) arrivalTime else departureTime
    val local = if (includeDelay) scheduled.plusMinutes(delayMinutes.toLong()) else scheduled
    if (airport == null) return ShownTime(local.format(clockFormat), "")

    val atAirport = local.atZone(airport.zone)
    if (!forceSystemZone) {
        return ShownTime(
            clock = local.format(clockFormat),
            zoneTag = gmtTag(atAirport.offset.totalSeconds)
        )
    }

    val systemZone = ZoneId.systemDefault()
    val atHome = atAirport.withZoneSameInstant(systemZone)
    val aheadBy = (atAirport.offset.totalSeconds - atHome.offset.totalSeconds) / 60
    val abbrev = atHome.format(zoneAbbrev)
    return ShownTime(
        clock = atHome.format(clockFormat),
        zoneTag = if (aheadBy == 0) abbrev else "$abbrev(${signedHours(aheadBy)})"
    )
}

private fun gmtTag(offsetSeconds: Int): String {
    val minutes = offsetSeconds / 60
    val sign = if (minutes < 0) "-" else "+"
    val hours = abs(minutes) / 60
    val mins = abs(minutes) % 60
    return if (mins == 0) "GMT$sign$hours" else "GMT$sign$hours:${"%02d".format(mins)}"
}

private fun signedHours(minutes: Int): String {
    val sign = if (minutes < 0) "-" else "+"
    val hours = abs(minutes) / 60
    val mins = abs(minutes) % 60
    return if (mins == 0) "$sign$hours" else "$sign$hours:${"%02d".format(mins)}"
}
