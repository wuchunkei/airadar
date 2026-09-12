package com.airadar.app.data

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

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
    /** ATC callsign (ICAO airline code + number), e.g. CPA392 for CX392. */
    val callsign: String? = null,
    /** Actual flown positions from ADS-B, once fetched; null means great circle only. */
    val track: List<TrackPoint>? = null,
    /** The day the stored track was flown — an earlier date when borrowed for a future leg. */
    val trackFlownOn: java.time.LocalDate? = null
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

data class TrackPoint(val lat: Double, val lon: Double)

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

data class TravelStats(
    val totalDistanceKm: Int,
    val flightCount: Int,
    val countryCount: Int,
    val cityCount: Int
)

data class UserSettings(
    val isLoggedIn: Boolean = false,
    val calendarSyncEnabled: Boolean = false,
    /** Show every time in the phone's zone instead of each airport's own. */
    val forceSystemZone: Boolean = false,
    val userEmail: String? = null,
    val userName: String? = null
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
