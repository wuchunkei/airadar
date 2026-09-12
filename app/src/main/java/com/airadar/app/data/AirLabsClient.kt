package com.airadar.app.data

import com.airadar.app.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.IOException
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.concurrent.TimeUnit

/**
 * Flight status and airport reference data from AirLabs. This is the app's single
 * status source; the same calls move behind the backend once it exists, and the
 * [Flight] shape handed to the UI stays the same.
 */
object AirLabsClient {

    private const val BASE = "https://airlabs.co/api/v9"

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    class AirLabsException(message: String) : IOException(message)

    val isConfigured: Boolean get() = BuildConfig.AIRLABS_API_KEY.isNotBlank()

    /** Live status for one flight number. AirLabs answers for today ± a day or so. */
    suspend fun flight(flightNumber: String, date: LocalDate): Flight = withContext(Dispatchers.IO) {
        val json = get("flight", "flight_iata" to flightNumber.uppercase())
        val data = json.optJSONObject("response")
            ?: throw AirLabsException(
                "AirLabs has no live record of ${flightNumber.uppercase()}. It only tracks " +
                        "flights around the current day; a far-off date has no status yet."
            )
        parse(data, flightNumber.uppercase(), date)
    }

    /** Timetable entry for a flight number on a future date (no live status). */
    suspend fun schedule(flightNumber: String, date: LocalDate): Flight = withContext(Dispatchers.IO) {
        val json = get("schedules", "flight_iata" to flightNumber.uppercase())
        val rows = json.optJSONArray("response")
        if (rows == null || rows.length() == 0) {
            throw AirLabsException("AirLabs has no schedule for ${flightNumber.uppercase()}.")
        }
        val onDate = (0 until rows.length()).map { rows.getJSONObject(it) }
            .firstOrNull { it.optString("dep_time").startsWith(date.toString()) }
            ?: rows.getJSONObject(0)
        parse(onDate, flightNumber.uppercase(), date)
    }

    /** Reference data for an airport the bundled table does not know. */
    suspend fun airport(iata: String): Airport = withContext(Dispatchers.IO) {
        val json = get("airports", "iata_code" to iata.uppercase())
        val rows = json.optJSONArray("response")
        val row = rows?.optJSONObject(0)
            ?: throw AirLabsException("AirLabs has no airport with code ${iata.uppercase()}.")
        Airport(
            iata = row.getString("iata_code"),
            icao = row.optString("icao_code").ifBlank { "" },
            name = row.optString("name").ifBlank { iata.uppercase() },
            city = row.optString("city").ifBlank { row.optString("name") },
            country = row.optString("country_code"),
            countryCode = row.optString("country_code"),
            latitude = row.getDouble("lat"),
            longitude = row.getDouble("lng"),
            zoneId = row.optString("timezone").ifBlank { "UTC" }
        )
    }

    // ---- transport --------------------------------------------------------

    private fun get(path: String, vararg query: Pair<String, String>): JSONObject {
        val key = BuildConfig.AIRLABS_API_KEY
        if (key.isBlank()) {
            throw AirLabsException(
                "AirLabs key missing — add airlabs.apiKey to local.properties and rebuild."
            )
        }
        val url = "$BASE/$path".toHttpUrl().newBuilder()
            .addQueryParameter("api_key", key)
            .apply { query.forEach { (k, v) -> addQueryParameter(k, v) } }
            .build()

        val body = http.newCall(Request.Builder().url(url).build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful && text.isBlank()) {
                throw AirLabsException("AirLabs request failed (HTTP ${response.code}).")
            }
            text
        }

        val json = JSONObject(body)
        json.optJSONObject("error")?.let { error ->
            val code = error.optString("code")
            throw AirLabsException(
                when (code) {
                    "unknown_api_key", "wrong_api_key" -> "AirLabs rejected the API key."
                    "limit_reached" -> "AirLabs monthly quota used up."
                    "not_found" -> "AirLabs found nothing for that query."
                    else -> "AirLabs: ${error.optString("message", code)}"
                }
            )
        }
        return json
    }

    // ---- parsing ----------------------------------------------------------

    private suspend fun parse(row: JSONObject, flightNumber: String, date: LocalDate): Flight {
        val dep = row.optString("dep_iata").uppercase()
        val arr = row.optString("arr_iata").uppercase()
        if (dep.isBlank() || arr.isBlank()) {
            throw AirLabsException("AirLabs record for $flightNumber has no route.")
        }
        // Any airport AirLabs mentions can be placed: fetch and remember unknown ones.
        FlightDatabase.ensureAirport(dep) { airport(dep) }
        FlightDatabase.ensureAirport(arr) { airport(arr) }

        val schedDep = row.time("dep_time")
            ?: throw AirLabsException("AirLabs record for $flightNumber has no scheduled departure.")
        val schedArr = row.time("arr_time")
            ?: throw AirLabsException("AirLabs record for $flightNumber has no scheduled arrival.")

        val delayed = row.optInt("delayed", 0).coerceAtLeast(0)
        val status = row.optString("status")

        return Flight(
            id = "$flightNumber-$date",
            flightNumber = flightNumber,
            airlineName = row.optString("airline_name").ifBlank { flightNumber.take(2) },
            departure = dep,
            arrival = arr,
            departureTerminal = row.text("dep_terminal"),
            arrivalTerminal = row.text("arr_terminal"),
            departureGate = row.text("dep_gate"),
            arrivalGate = row.text("arr_gate"),
            departureTime = schedDep,
            arrivalTime = schedArr,
            status = statusFrom(status, delayed),
            aircraft = row.text("aircraft_icao"),
            baggageClaim = row.text("arr_baggage"),
            delayMinutes = delayed,
            // AirLabs supplies the ATC callsign as flight_icao.
            callsign = row.text("flight_icao")
                ?: FlightDatabase.airlineIcao(flightNumber.takeWhile { it.isLetter() })
                    ?.let { it + flightNumber.filter(Char::isDigit) }
        )
    }

    private val localTime: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    /** AirLabs local times look like `2026-09-21 02:30`. */
    private fun JSONObject.time(key: String): LocalDateTime? =
        text(key)?.let { raw ->
            try {
                LocalDateTime.parse(raw.take(16), localTime)
            } catch (_: DateTimeParseException) {
                null
            }
        }

    private fun JSONObject.text(key: String): String? =
        optString(key).takeIf { has(key) && !isNull(key) && it.isNotBlank() && it != "null" }

    private fun statusFrom(status: String, delayMinutes: Int): FlightStatus = when (status) {
        "cancelled" -> FlightStatus.CANCELLED
        "diverted" -> FlightStatus.DIVERTED
        "landed" -> FlightStatus.LANDED
        "active" -> FlightStatus.IN_FLIGHT
        else -> if (delayMinutes > 0) FlightStatus.DELAYED else FlightStatus.SCHEDULED
    }
}
