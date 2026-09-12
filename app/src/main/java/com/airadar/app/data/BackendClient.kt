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
import java.time.format.DateTimeParseException
import java.util.concurrent.TimeUnit

/**
 * The Airadar backend (backend/ in this repo). It is the app's only flight-status
 * source: the AirLabs key stays on the server, and the wire shape mirrors [Flight]
 * field for field, so nothing here has to know which provider answered.
 */
object BackendClient {

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    class BackendException(message: String) : IOException(message)

    val isConfigured: Boolean get() = BuildConfig.BACKEND_URL.isNotBlank()

    /** Status for one flight number on one date; the server picks live vs timetable. */
    suspend fun flight(flightNumber: String, date: LocalDate): Flight = withContext(Dispatchers.IO) {
        val number = flightNumber.uppercase()
        parse(get("flights/$number/$date"), number, date)
    }

    /** Reference data for an airport the bundled table does not know. */
    suspend fun airport(iata: String): Airport = withContext(Dispatchers.IO) {
        val row = get("airports/${iata.uppercase()}")
        Airport(
            iata = row.getString("iata"),
            icao = row.optString("icao"),
            name = row.optString("name").ifBlank { iata.uppercase() },
            city = row.optString("city").ifBlank { iata.uppercase() },
            country = row.optString("country"),
            countryCode = row.optString("countryCode"),
            latitude = row.getDouble("latitude"),
            longitude = row.getDouble("longitude"),
            zoneId = row.optString("zoneId").ifBlank { "UTC" }
        )
    }

    // ---- transport --------------------------------------------------------

    private fun get(path: String): JSONObject {
        val base = BuildConfig.BACKEND_URL.trimEnd('/')
        if (base.isBlank()) {
            throw BackendException("Backend address missing — set backend.url in local.properties and rebuild.")
        }
        val request = Request.Builder()
            .url("$base/$path".toHttpUrl())
            .apply {
                BuildConfig.BACKEND_TOKEN.takeIf { it.isNotBlank() }?.let { header("X-Airadar-Token", it) }
            }
            .build()

        val (code, body) = try {
            http.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
        } catch (e: IOException) {
            throw BackendException("Could not reach the Airadar server: ${e.message ?: e.javaClass.simpleName}")
        }

        if (code in 200..299) return JSONObject(body)

        // FastAPI wraps errors as {"detail": ...}; ours carry an object with "error".
        val detail = runCatching { JSONObject(body).opt("detail") }.getOrNull()
        val reason = when (detail) {
            is JSONObject -> detail.optString("error").ifBlank { detail.toString() }
            null -> ""
            else -> detail.toString()
        }
        throw BackendException(
            when (code) {
                401 -> "The server rejected this build's token (backend.token in local.properties)."
                404 -> "Nothing found for that flight on that date."
                429 -> "AirLabs monthly quota used up on the server."
                else -> reason.ifBlank { "Airadar server error (HTTP $code)." }
            }
        )
    }

    // ---- parsing ----------------------------------------------------------

    private suspend fun parse(row: JSONObject, flightNumber: String, date: LocalDate): Flight {
        val dep = row.getString("departure").uppercase()
        val arr = row.getString("arrival").uppercase()
        // Any airport the server mentions can be placed: fetch and remember unknown ones.
        FlightDatabase.ensureAirport(dep) { airport(dep) }
        FlightDatabase.ensureAirport(arr) { airport(arr) }

        return Flight(
            id = row.optString("id").ifBlank { "$flightNumber-$date" },
            flightNumber = row.optString("flightNumber").ifBlank { flightNumber },
            airlineName = row.optString("airlineName").ifBlank { flightNumber.take(2) },
            departure = dep,
            arrival = arr,
            departureTerminal = row.text("departureTerminal"),
            arrivalTerminal = row.text("arrivalTerminal"),
            departureGate = row.text("departureGate"),
            arrivalGate = row.text("arrivalGate"),
            departureTime = row.time("departureTime")
                ?: throw BackendException("Record for $flightNumber has no scheduled departure."),
            arrivalTime = row.time("arrivalTime")
                ?: throw BackendException("Record for $flightNumber has no scheduled arrival."),
            status = runCatching { FlightStatus.valueOf(row.optString("status")) }
                .getOrDefault(FlightStatus.SCHEDULED),
            aircraft = row.text("aircraft"),
            baggageClaim = row.text("baggageClaim"),
            delayMinutes = row.optInt("delayMinutes", 0).coerceAtLeast(0),
            callsign = row.text("callsign")
                ?: FlightDatabase.airlineIcao(flightNumber.takeWhile { it.isLetter() })
                    ?.let { it + flightNumber.filter(Char::isDigit) }
        )
    }

    /** Server times are ISO local: `2026-09-21T02:30:00`. */
    private fun JSONObject.time(key: String): LocalDateTime? =
        text(key)?.let { raw ->
            try {
                LocalDateTime.parse(raw.take(19))
            } catch (_: DateTimeParseException) {
                null
            }
        }

    private fun JSONObject.text(key: String): String? =
        optString(key).takeIf { has(key) && !isNull(key) && it.isNotBlank() && it != "null" }
}
