package com.airadar.app.data

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime

private data class Schedule(
    val flightNumber: String,
    val airlineName: String,
    val airlineIcao: String,
    val from: String,
    val to: String,
    val departLocal: LocalTime,
    val arriveLocal: LocalTime,
    val arrivesNextDay: Boolean = false,
    val fromTerminal: String? = null,
    val toTerminal: String? = null,
    val aircraft: String? = null,
    val baggageClaim: String? = null
)

object FlightDatabase {

    private val airports = listOf(
        Airport("SZX", "ZGSZ", "Shenzhen Bao'an", "Shenzhen", "China", "CN", 22.639, 113.811, "Asia/Shanghai"),
        Airport("ICN", "RKSI", "Incheon", "Seoul", "South Korea", "KR", 37.469, 126.451, "Asia/Seoul"),
        Airport("HKG", "VHHH", "Hong Kong", "Hong Kong", "Hong Kong", "HK", 22.308, 113.918, "Asia/Hong_Kong"),
        Airport("PEK", "ZBAA", "Beijing Capital", "Beijing", "China", "CN", 40.080, 116.585, "Asia/Shanghai"),
        Airport("PVG", "ZSPD", "Shanghai Pudong", "Shanghai", "China", "CN", 31.143, 121.805, "Asia/Shanghai"),
        Airport("CAN", "ZGGG", "Guangzhou Baiyun", "Guangzhou", "China", "CN", 23.392, 113.299, "Asia/Shanghai"),
        Airport("MFM", "VMMC", "Macau", "Macau", "Macau", "MO", 22.150, 113.592, "Asia/Macau"),
        Airport("TPE", "RCTP", "Taoyuan", "Taipei", "Taiwan", "TW", 25.077, 121.233, "Asia/Taipei"),
        Airport("NRT", "RJAA", "Narita", "Tokyo", "Japan", "JP", 35.765, 140.386, "Asia/Tokyo"),
        Airport("HND", "RJTT", "Haneda", "Tokyo", "Japan", "JP", 35.553, 139.781, "Asia/Tokyo"),
        Airport("KIX", "RJBB", "Kansai", "Osaka", "Japan", "JP", 34.434, 135.233, "Asia/Tokyo"),
        Airport("SIN", "WSSS", "Changi", "Singapore", "Singapore", "SG", 1.364, 103.991, "Asia/Singapore"),
        Airport("BKK", "VTBS", "Suvarnabhumi", "Bangkok", "Thailand", "TH", 13.690, 100.750, "Asia/Bangkok"),
        Airport("KUL", "WMKK", "Kuala Lumpur", "Kuala Lumpur", "Malaysia", "MY", 2.746, 101.710, "Asia/Kuala_Lumpur"),
        Airport("LHR", "EGLL", "Heathrow", "London", "United Kingdom", "GB", 51.470, -0.454, "Europe/London"),
        Airport("CDG", "LFPG", "Charles de Gaulle", "Paris", "France", "FR", 49.010, 2.548, "Europe/Paris"),
        Airport("JFK", "KJFK", "John F. Kennedy", "New York", "United States", "US", 40.641, -73.778, "America/New_York"),
        Airport("SFO", "KSFO", "San Francisco", "San Francisco", "United States", "US", 37.619, -122.375, "America/Los_Angeles"),
        Airport("LAX", "KLAX", "Los Angeles", "Los Angeles", "United States", "US", 33.942, -118.408, "America/Los_Angeles"),
        Airport("SYD", "YSSY", "Kingsford Smith", "Sydney", "Australia", "AU", -33.946, 151.177, "Australia/Sydney")
    ).associateBy { it.iata }

    private val schedules = listOf(
        Schedule("OZ372", "Asiana Airlines", "AAR", "SZX", "ICN",
            LocalTime.of(2, 30), LocalTime.of(7, 0),
            fromTerminal = "3", toTerminal = "2", aircraft = "Airbus A321"),
        Schedule("CX392", "Cathay Pacific", "CPA", "PEK", "HKG",
            LocalTime.of(13, 25), LocalTime.of(16, 2),
            fromTerminal = "3", toTerminal = "1", aircraft = "Airbus A330", baggageClaim = "7"),
        Schedule("CA826", "Air China", "CCA", "SIN", "PVG",
            LocalTime.of(17, 50), LocalTime.of(23, 20),
            fromTerminal = "1", toTerminal = "2", aircraft = "Boeing 787", baggageClaim = "24"),
        Schedule("JL802", "Japan Airlines", "JAL", "TPE", "NRT",
            LocalTime.of(10, 0), LocalTime.of(14, 10),
            fromTerminal = "2", toTerminal = "2", aircraft = "Boeing 767"),
        Schedule("MM28", "Peach Aviation", "APJ", "TPE", "KIX",
            LocalTime.of(18, 45), LocalTime.of(22, 30),
            fromTerminal = "1", toTerminal = "2", aircraft = "Airbus A320"),
        Schedule("CX880", "Cathay Pacific", "CPA", "HKG", "LAX",
            LocalTime.of(0, 55), LocalTime.of(21, 55), aircraft = "Boeing 777",
            fromTerminal = "1", toTerminal = "B"),
        Schedule("SQ862", "Singapore Airlines", "SIA", "SIN", "HKG",
            LocalTime.of(8, 5), LocalTime.of(12, 5),
            fromTerminal = "3", toTerminal = "1", aircraft = "Airbus A350"),
        Schedule("BA28", "British Airways", "BAW", "HKG", "LHR",
            LocalTime.of(23, 55), LocalTime.of(5, 40), arrivesNextDay = true,
            fromTerminal = "1", toTerminal = "5", aircraft = "Boeing 777"),
        Schedule("NH880", "All Nippon Airways", "ANA", "HND", "HKG",
            LocalTime.of(9, 30), LocalTime.of(13, 15),
            fromTerminal = "3", toTerminal = "1", aircraft = "Boeing 787"),
        Schedule("TG607", "Thai Airways", "THA", "BKK", "HKG",
            LocalTime.of(8, 0), LocalTime.of(11, 45),
            fromTerminal = "1", toTerminal = "1", aircraft = "Airbus A330")
    ).associateBy { it.flightNumber.uppercase() }

    // Two-letter IATA marketing code -> three-letter ICAO code used in ATC callsigns.
    private val airlineIcaoByIata = mapOf(
        "CX" to "CPA", "KA" to "HDA", "OZ" to "AAR", "KE" to "KAL", "CA" to "CCA",
        "MU" to "CES", "CZ" to "CSN", "HU" to "CHH", "3U" to "CSC", "MF" to "CXA",
        "ZH" to "CSZ", "HO" to "DKH", "9C" to "CQH", "JL" to "JAL", "NH" to "ANA",
        "MM" to "APJ", "GK" to "JJP", "SQ" to "SIA", "TR" to "TGW", "TG" to "THA",
        "BR" to "EVA", "CI" to "CAL", "MH" to "MAS", "AK" to "AXM", "BA" to "BAW",
        "VS" to "VIR", "AF" to "AFR", "LH" to "DLH", "QF" to "QFA", "UA" to "UAL",
        "AA" to "AAL", "DL" to "DAL", "EK" to "UAE", "QR" to "QTR", "NX" to "AMU"
    )

    fun airlineIcao(iata: String): String? = airlineIcaoByIata[iata.uppercase()]

    // Airports learned at runtime from AirLabs, so any route can be placed on the map.
    private val learned = java.util.concurrent.ConcurrentHashMap<String, Airport>()

    fun airport(iata: String): Airport? = airports[iata.uppercase()] ?: learned[iata.uppercase()]

    /** Makes sure [iata] is known, fetching it once if the bundled table lacks it. */
    suspend fun ensureAirport(iata: String, fetch: suspend () -> Airport) {
        val code = iata.uppercase()
        if (airports.containsKey(code) || learned.containsKey(code)) return
        learned[code] = fetch()
    }

    fun allAirports(): List<Airport> = airports.values.toList()

    fun lookup(flightNumber: String, date: LocalDate): Flight? {
        val schedule = schedules[flightNumber.uppercase().replace(" ", "")] ?: return null
        return schedule.toFlight(date)
    }

    /**
     * Booking lookup needs a GDS contract (Amadeus, Sabre, Travelport) or each
     * airline's own member API — there is no open source for it, so nothing is
     * resolved locally.
     */
    fun lookupByPnr(pnr: String, lastName: String): List<Flight> = emptyList()

    private fun Flight.defaultStatus(): FlightStatus = when (phase) {
        FlightPhase.PAST -> FlightStatus.COMPLETED
        FlightPhase.IN_PROGRESS -> FlightStatus.IN_FLIGHT
        FlightPhase.UPCOMING -> FlightStatus.SCHEDULED
    }

    private fun Schedule.toFlight(date: LocalDate): Flight {
        val arrivalDate = if (arrivesNextDay) date.plusDays(1) else date
        return Flight(
            id = "$flightNumber-$date",
            flightNumber = flightNumber,
            airlineName = airlineName,
            departure = from,
            arrival = to,
            departureTerminal = fromTerminal,
            arrivalTerminal = toTerminal,
            departureTime = LocalDateTime.of(date, departLocal),
            arrivalTime = LocalDateTime.of(arrivalDate, arriveLocal),
            aircraft = aircraft,
            baggageClaim = baggageClaim,
            callsign = airlineIcao + flightNumber.filter(Char::isDigit)
        ).let { it.copy(status = it.defaultStatus()) }
    }
}
