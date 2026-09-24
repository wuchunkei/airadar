package com.airadar.app.data

import androidx.compose.runtime.Immutable
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

@Immutable
data class Airport(
    val iata: String,
    /** ICAO location indicator — what ADS-B feeds key airports by. */
    val icao: String,
    val name: String,
    val city: String,
    val country: String,
    /** ISO 3166-1 alpha-2, shown next to the city on trip cards. */
    val countryCode: String,
    val latitude: Double,
    val longitude: Double,
    val zoneId: String
) {
    val zone: ZoneId get() = ZoneId.of(zoneId)
}

@Immutable
data class Flight(
    val id: String = "",
    val flightNumber: String,
    val airlineName: String = "",
    val departure: String,
    val arrival: String,
    val departureTerminal: String? = null,
    val arrivalTerminal: String? = null,
    val departureGate: String? = null,
    val arrivalGate: String? = null,
    val departureTime: LocalDateTime,
    val arrivalTime: LocalDateTime,
    val status: FlightStatus = FlightStatus.ON_TIME,
    val aircraft: String? = null,
    val pnr: String? = null,
    val delayMinutes: Int = 0,
    /** How far the arrival moved from the timetable, from the source's own
     * estimated or actual arrival: negative early, positive late, null when it
     * hasn't said. Separate from [delayMinutes] (the departure's). */
    val arrivalDelayMinutes: Int? = null,
    val baggageClaim: String? = null,
    val typicalDurationMinutes: Int? = null,
    /** Imported from a mailbox and not yet confirmed by the traveller. */
    val isPending: Boolean = false,
    /** Typed in by hand because no source knew it; shown with a warning block. */
    val isManual: Boolean = false,
    /** Set only on a flight fed this way (see FeedStatus) — null for anything
     * else. Never trust this at face value on its own: the server resolves
     * it from PENDING to a real verdict (and, if the automated scorer can't
     * decide, community review) before it's ever stored. */
    val feedStatus: FeedStatus? = null,
    /** Where this trip was found: "gmail" or "calendar" — null for one the
     * backend already knew, one typed by hand, or one pasted as plain text. */
    val importedVia: String? = null,
    /** Names found on the ticket text this trip was imported from. */
    val passengers: List<String> = emptyList(),
    /** ATC callsign (ICAO airline code + number), e.g. CPA392 for CX392. */
    val callsign: String? = null,
    /** Actual flown positions from ADS-B, once fetched; null means great circle only. */
    val track: List<TrackPoint>? = null,
    /** The day the stored track was flown — an earlier date when borrowed for a future leg. */
    val trackFlownOn: java.time.LocalDate? = null,
    /** Set while the trip sits in the recycle bin; cleared on restore. */
    val deletedAt: Instant? = null,
    /** A friend's trip shown on my list: who shared it and where I stand on it. */
    val sharedBy: TripShare? = null,
    /** My trip shared with friends: each of them and where they stand. */
    val shares: List<TripShare> = emptyList()
) {
    val departureAirport: Airport? get() = FlightDatabase.airport(departure)
    val arrivalAirport: Airport? get() = FlightDatabase.airport(arrival)

    val departureInstant: Instant?
        get() = departureAirport?.let { departureTime.atZone(it.zone).toInstant() }

    val arrivalInstant: Instant?
        get() = arrivalAirport?.let { arrivalTime.atZone(it.zone).toInstant() }

    /** Minutes the arrival moved: the source's own arrival figure when it has
     * one, else the departure delay carried through. */
    val arrivalShiftMinutes: Int
        get() = arrivalDelayMinutes ?: delayMinutes

    /** When it lands (or landed), as best known. */
    val expectedArrival: Instant?
        get() = arrivalInstant?.plusSeconds(arrivalShiftMinutes * 60L)

    /** Where this flight sits relative to right now, across time zones. */
    val phase: FlightPhase
        get() {
            val dep = departureInstant ?: return FlightPhase.UPCOMING
            val arr = expectedArrival ?: return FlightPhase.UPCOMING
            val now = Instant.now()
            return when {
                now.isBefore(dep) -> FlightPhase.UPCOMING
                now.isAfter(arr) -> FlightPhase.PAST
                else -> FlightPhase.IN_PROGRESS
            }
        }

    /** What the status should read once the clock alone already knows the
     * flight is over — a source that never polls again after departure can
     * leave a real trip stuck reading "Scheduled" long after it landed.
     * Cancelled and diverted stay as they are; those are real outcomes worth keeping. */
    val displayStatus: FlightStatus
        get() {
            if (trackDiverged) return FlightStatus.DIVERTED
            if (phase != FlightPhase.PAST || status == FlightStatus.CANCELLED || status == FlightStatus.DIVERTED) return status
            return FlightStatus.LANDED
        }

    /** A real track whose last known fix, once the schedule says the flight
     * is over, sits nowhere near the airport it was supposed to land at --
     * a diversion or a return to origin looks identical from here, and
     * either way the schedule's own status can't be trusted for this trip
     * anymore, whatever it claims. Never checked mid-route -- being far
     * from the destination is simply what "still flying" looks like. 100km,
     * not a tighter number, so a track that merely lost ADS-B coverage a
     * little early on final approach doesn't misread as a diversion. */
    // And only a track that still reaches the end of the flight counts: one that
    // simply stops early (out of receiver range, or only the first minutes caught)
    // says where coverage ended, not where the plane did. Nor when the source
    // already has the arrival: that is the airline saying it landed where it was going.
    private val trackDiverged: Boolean
        get() {
            if (phase != FlightPhase.PAST || arrivalDelayMinutes != null) return false
            val last = cleanTrack?.lastOrNull() ?: return false
            val seen = last.time ?: return false
            val expected = expectedArrival ?: return false
            if (seen.isBefore(expected.minusSeconds(30 * 60))) return false
            val arrival = arrivalAirport ?: return false
            return greatCircleKm(last.lat, last.lon, arrival.latitude, arrival.longitude) > 100
        }

    /** The stored track with its impossible points taken out — see [cleanedTrack]. */
    val cleanTrack: List<TrackPoint>?
        get() = track?.let(::cleanedTrack)

    /** The real track's last known fix, only when it's genuine evidence the
     * flight didn't reach where it was scheduled to -- for naming where it
     * actually ended up, on top of `displayStatus` already reading Diverted. */
    val divergedLastFix: TrackPoint?
        get() = if (trackDiverged) cleanTrack?.lastOrNull() else null

    val durationMinutes: Int
        get() {
            if (trackDiverged) {
                val start = cleanTrack?.firstOrNull()?.time
                val end = cleanTrack?.lastOrNull()?.time
                if (start != null && end != null) return (java.time.Duration.between(start, end).toMinutes()).toInt().coerceAtLeast(0)
            }
            val dep = departureInstant ?: return 0
            val arr = arrivalInstant ?: return 0
            // Door to door as it actually went, once the source has an arrival figure.
            val moved = arrivalDelayMinutes?.let { it - delayMinutes } ?: 0
            return (((arr.toEpochMilli() - dep.toEpochMilli()) / 60000).toInt() + moved).coerceAtLeast(0)
        }

    /** Share of the way flown by the clock -- used to place a schedule-
     * estimated plane along the arc when there's no real ADS-B fix yet. */
    val fractionFlown: Double
        get() {
            val dep = departureInstant ?: return 0.0
            val arr = arrivalInstant ?: return 0.0
            val delayed = dep.plusSeconds(delayMinutes * 60L)
            val total = arr.toEpochMilli() - dep.toEpochMilli()
            if (total <= 0) return 0.0
            val elapsed = java.time.Instant.now().toEpochMilli() - delayed.toEpochMilli()
            return (elapsed.toDouble() / total).coerceIn(0.0, 1.0)
        }

    val distanceKm: Int
        get() {
            if (trackDiverged) {
                val points = cleanTrack
                if (points != null && points.size >= 2) {
                    var total = 0
                    for (i in 0 until points.size - 1) {
                        total += greatCircleKm(points[i].lat, points[i].lon, points[i + 1].lat, points[i + 1].lon)
                    }
                    return total
                }
            }
            val dep = departureAirport ?: return 0
            val arr = arrivalAirport ?: return 0
            return greatCircleKm(dep.latitude, dep.longitude, arr.latitude, arr.longitude)
        }
}

enum class FlightPhase { PAST, IN_PROGRESS, UPCOMING }

@Immutable
data class TrackPoint(
    val lat: Double,
    val lon: Double,
    /** When this position was actually reported over ADS-B -- null only for a
     * point decoded before this field existed (an already-cached track on
     * disk); every freshly fetched one carries a real one. */
    val time: java.time.Instant? = null
)

enum class FlightStatus {
    ON_TIME,
    DELAYED,
    CANCELLED,
    DIVERTED,
    SCHEDULED,
    COMPLETED,
    BOARDING,
    DEPARTED,
    IN_FLIGHT,
    LANDED
}

/** A manually-entered ("fed") flight's automated verification outcome — the
 * server, never the client, decides which of these it ends up as: it
 * re-checks a fresh PENDING against AirLabs/AeroDataBox's own schedules,
 * adsbdb's independent route data, and other travellers' own fed flights
 * (backend/app/feed.py), and hands anything it can't settle either way to
 * community review (backend/app/community.py) instead of leaving it stuck. */
enum class FeedStatus { PENDING, APPROVED, REJECTED, EXPIRED }

/** A real person can't be on two flights at once — the one integrity check
 * this needs no external source for, just the traveller's own other
 * flights. An overlap is a strong sign one of the two was actually
 * imported from someone else's ticket (a shared inbox, a family member's
 * calendar invite) rather than genuinely this traveller's own. */
object FlightConflicts {
    /** Another of the traveller's own flights (never a friend's shared one,
     * on either side) whose time in the air overlaps this one's, or null. */
    fun overlapping(flight: Flight, all: List<Flight>): Flight? {
        if (flight.sharedBy != null || flight.status == FlightStatus.CANCELLED) return null
        val dep = flight.departureInstant ?: return null
        val arr = flight.arrivalInstant ?: return null
        return all.firstOrNull { other ->
            val otherDep = other.departureInstant
            val otherArr = other.arrivalInstant
            other.id != flight.id && other.sharedBy == null && other.deletedAt == null &&
                other.status != FlightStatus.CANCELLED &&
                otherDep != null && otherArr != null &&
                dep.isBefore(otherArr) && otherDep.isBefore(arr)
        }
    }
}

data class TravelStats(
    val totalDistanceKm: Int,
    val flightCount: Int,
    val countryCount: Int,
    val cityCount: Int
)

enum class ThemeMode { SYSTEM, LIGHT, DARK }

@Immutable
data class UserSettings(
    val isLoggedIn: Boolean = false,
    val calendarSyncEnabled: Boolean = false,
    /** Show every time in the phone's zone instead of each airport's own. */
    val forceSystemZone: Boolean = false,
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    val userEmail: String? = null,
    val userName: String? = null,
    /** The traveller's own colour, as friends see them. */
    val color: String? = null,
    val findableByEmail: Boolean = false,
    val membership: Membership = Membership.GUEST
)

/** The three countries that still measure road and air distance in miles. */
fun systemPrefersMetric(): Boolean =
    java.util.Locale.getDefault().country.uppercase() !in setOf("US", "LR", "MM")

fun formatDistance(km: Int): String =
    if (systemPrefersMetric()) "%,d km".format(km)
    else "%,d mi".format((km * 0.621371).toInt())

fun greatCircleKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Int {
    val r = 6371.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2)
    return (r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))).toInt()
}

/**
 * A track in time order with its impossible points dropped: a fix no airliner
 * could have reached from its neighbours (faster than 1,300 km/h) is some other
 * aircraft's, or a garbled one — left in, it zigzags the drawn line and can end
 * the track somewhere the flight never went. Same rules as iOS's TrackPoint.cleaned.
 */
fun cleanedTrack(points: List<TrackPoint>): List<TrackPoint> {
    val out = (if (points.all { it.time != null }) points.sortedBy { it.time } else points).toMutableList()
    fun impossible(a: TrackPoint, b: TrackPoint): Boolean {
        val ta = a.time ?: return false
        val tb = b.time ?: return false
        val km = greatCircleKm(a.lat, a.lon, b.lat, b.lon).toDouble()
        val hours = kotlin.math.abs(java.time.Duration.between(ta, tb).seconds) / 3600.0
        return if (hours > 0) km / hours > 1300 else km > 5
    }
    while (out.size >= 3) {
        val n = out.size
        // A point in the middle out of line with both neighbours: a stray.
        val stray = (1 until n - 1).firstOrNull { impossible(out[it - 1], out[it]) && impossible(out[it], out[it + 1]) }
        when {
            stray != null -> out.removeAt(stray)
            // An end point out of line with a neighbour that itself agrees with the next one in.
            impossible(out[0], out[1]) && !impossible(out[1], out[2]) -> out.removeAt(0)
            impossible(out[n - 2], out[n - 1]) && !impossible(out[n - 3], out[n - 2]) -> out.removeAt(n - 1)
            else -> break
        }
    }
    return out
}
