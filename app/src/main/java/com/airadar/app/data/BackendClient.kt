package com.airadar.app.data

import com.airadar.app.BuildConfig
import org.json.JSONArray
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.Mutex
import android.os.Build
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

    class BackendException(message: String, val code: Int = 0) : IOException(message)

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

    // ---- account ------------------------------------------------------------

    /** Trades a Google ID token for this server's own session; stores it. */
    suspend fun signInWithGoogle(idToken: String): AuthUser = withContext(Dispatchers.IO) {
        val body = JSONObject().put("idToken", idToken).put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
        storeSession(call("POST", "auth/google", body))
    }

    suspend fun signOut() = withContext(Dispatchers.IO) {
        AuthStore.refreshToken?.let { token ->
            runCatching { call("POST", "auth/logout", JSONObject().put("refreshToken", token)) }
        }
        AuthStore.clear()
    }

    private val refreshLock = Mutex()

    /**
     * Swaps the refresh token for a new pair. Serialised: two requests that both
     * hit a 401 must not both spend the same refresh token.
     */
    private suspend fun refreshSession(): Boolean {
        refreshLock.withLock {
            val token = AuthStore.refreshToken ?: return false
            return try {
                storeSession(call("POST", "auth/refresh", JSONObject().put("refreshToken", token)))
                true
            } catch (e: BackendException) {
                // Only a definite "no" ends the session; a dead network keeps it.
                if (e.code == 401) AuthStore.clear()
                false
            }
        }
    }

    private fun storeSession(json: JSONObject): AuthUser {
        val u = json.getJSONObject("user")
        val user = AuthUser(u.getString("id"), u.getString("email"), u.text("name"), u.text("avatarUrl"))
        AuthStore.save(json.getString("accessToken"), json.getString("refreshToken"), user)
        return user
    }

    // ---- trips ---------------------------------------------------------------

    suspend fun listTrips(deleted: Boolean = false): List<Flight> = withContext(Dispatchers.IO) {
        val arr = authed("GET", if (deleted) "trips/deleted" else "trips").getJSONArray("items")
        (0 until arr.length()).map { flightFromJson(arr.getJSONObject(it)) }
            .also { list -> list.forEach { ensureAirports(it.departure, it.arrival) } }
    }

    suspend fun putTrip(flight: Flight): Unit = withContext(Dispatchers.IO) {
        authed("PUT", "trips/${flight.id}", flight.toJson())
    }

    suspend fun deleteTrip(id: String): Unit = withContext(Dispatchers.IO) {
        authed("DELETE", "trips/$id")
    }

    suspend fun restoreTrip(id: String): Unit = withContext(Dispatchers.IO) {
        authed("POST", "trips/$id/restore")
    }

    private suspend fun ensureAirports(vararg codes: String) {
        codes.forEach { code -> FlightDatabase.ensureAirport(code) { airport(code) } }
    }

    // ---- transport --------------------------------------------------------

    private fun get(path: String): JSONObject = call("GET", path)

    /** A signed-in call: retried once with a fresh access token after a 401. */
    private suspend fun authed(method: String, path: String, body: JSONObject? = null): JSONObject {
        val first = AuthStore.accessToken ?: throw BackendException("Sign in required.", 401)
        return try {
            call(method, path, body, bearer = first)
        } catch (e: BackendException) {
            if (e.code != 401 || !refreshSession()) throw e
            call(method, path, body, bearer = AuthStore.accessToken)
        }
    }

    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    private fun call(method: String, path: String, body: JSONObject? = null, bearer: String? = null): JSONObject {
        val base = BuildConfig.BACKEND_URL.trimEnd('/')
        if (base.isBlank()) {
            throw BackendException("Backend address missing — set backend.url in local.properties and rebuild.")
        }
        // OkHttp insists on a body for POST/PUT, even an empty one, and none for GET.
        val requestBody = body?.toString()?.toRequestBody(jsonMedia)
            ?: if (method == "GET") null else ByteArray(0).toRequestBody(null)
        val request = Request.Builder()
            .url("$base/$path".toHttpUrl())
            .method(method, requestBody)
            .apply {
                BuildConfig.BACKEND_TOKEN.takeIf { it.isNotBlank() }?.let { header("X-Airadar-Token", it) }
                bearer?.let { header("Authorization", "Bearer $it") }
            }
            .build()

        val (code, text) = try {
            http.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
        } catch (e: IOException) {
            throw BackendException("Could not reach the Airadar server: ${e.message ?: e.javaClass.simpleName}")
        }

        if (code in 200..299) {
            // Lists arrive as a bare array; wrap so every caller sees an object.
            val trimmed = text.trim()
            return when {
                trimmed.startsWith("[") -> JSONObject().put("items", JSONArray(trimmed))
                trimmed.isEmpty() -> JSONObject()
                else -> JSONObject(trimmed)
            }
        }

        // FastAPI wraps errors as {"detail": ...}; ours carry an object with "error".
        val detail = runCatching { JSONObject(text).opt("detail") }.getOrNull()
        val reason = when (detail) {
            is JSONObject -> detail.optString("error").ifBlank { detail.toString() }
            null -> ""
            else -> detail.toString()
        }
        throw BackendException(
            when (code) {
                401 -> reason.ifBlank { "The server rejected this build's token (backend.token in local.properties)." }
                404 -> if (path.startsWith("flights/")) "Nothing found for that flight on that date." else reason.ifBlank { "Not found." }
                429 -> "AirLabs monthly quota used up on the server."
                else -> reason.ifBlank { "Airadar server error (HTTP $code)." }
            },
            code
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
