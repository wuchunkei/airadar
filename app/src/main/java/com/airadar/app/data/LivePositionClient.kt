package com.airadar.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.TimeUnit

/**
 * Where an aircraft is right now, from adsb.lol's community ADS-B feed --
 * documented, free, no approval needed, keyed by the ATC callsign, answers
 * within a second or two. airplanes.live's own API looks equivalent on paper
 * but gates every endpoint behind a manual "email us first" approval
 * (confirmed live -- every call, even a bare lookup, comes back 403 until
 * then), so it isn't used here at all.
 */
data class LivePosition(
    val lat: Double,
    val lon: Double,
    /** Degrees clockwise from north. */
    val heading: Double,
    val altitudeFeet: Int?,
    /** The airframe's Mode-S / ICAO24 hex -- what adsbdb keys its aircraft
     * lookup by, and what OpenSky's own per-aircraft history is keyed by too. */
    val hex: String?,
    val seenAt: Instant
)

object LivePositionClient {

    private const val SOURCE = "https://api.adsb.lol/v2/callsign/"

    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .build()

    /** The latest position for a callsign, or null when no feeder hears it. */
    suspend fun position(callsign: String): LivePosition? = withContext(Dispatchers.IO) {
        val wanted = callsign.trim().uppercase()
        val request = Request.Builder().url(SOURCE + wanted).build()
        val body = try {
            http.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                resp.body?.string()
            }
        } catch (_: Exception) {
            null
        } ?: return@withContext null

        val aircraft = try {
            JSONObject(body).optJSONArray("ac")
        } catch (_: Exception) {
            null
        } ?: return@withContext null

        // Callsigns are padded to eight characters on the wire; match on the trimmed form.
        var match: JSONObject? = null
        for (i in 0 until aircraft.length()) {
            val ac = aircraft.getJSONObject(i)
            if (ac.optString("flight").trim().uppercase() == wanted) {
                match = ac
                break
            }
        }
        val ac = match ?: (if (aircraft.length() > 0) aircraft.getJSONObject(0) else null) ?: return@withContext null
        if (!ac.has("lat") || !ac.has("lon")) return@withContext null

        val heading = if (ac.has("track")) ac.optDouble("track") else ac.optDouble("true_heading", 0.0)
        val alt = if (ac.has("alt_baro") && ac.optString("alt_baro") != "ground") ac.optInt("alt_baro")
        else if (ac.has("alt_geom")) ac.optInt("alt_geom") else null
        val ageSeconds = ac.optDouble("seen", 0.0)

        LivePosition(
            lat = ac.getDouble("lat"),
            lon = ac.getDouble("lon"),
            heading = heading,
            altitudeFeet = alt,
            hex = if (ac.has("hex")) ac.getString("hex") else null,
            seenAt = Instant.now().minusSeconds(ageSeconds.toLong())
        )
    }
}
