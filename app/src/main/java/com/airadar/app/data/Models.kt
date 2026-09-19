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

    /** Where this flight sits relative to right now, across time zones. */
    val phase: FlightPhase
        get() {
            val dep = departureInstant ?: return FlightPhase.UPCOMING
            val arr = arrivalInstant ?: return FlightPhase.UPCOMING
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
            if (phase != FlightPhase.PAST || status == FlightStatus.CANCELLED || status == FlightStatus.DIVERTED) return status
            return FlightStatus.LANDED
        }

    val durationMinutes: Int
        get() {
            val dep = departureInstant ?: return 0
            val arr = arrivalInstant ?: return 0
            return ((arr.toEpochMilli() - dep.toEpochMilli()) / 60000).toInt()
        }

    val distanceKm: Int
        get() {
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
