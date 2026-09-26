package com.airadar.app.data

import com.airadar.app.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.util.concurrent.TimeUnit

/**
 * Pulls the positions an aircraft actually reported over ADS-B, so a flown leg can
 * be drawn as the path it took rather than a great circle.
 *
 * OpenSky keys everything by the airframe's ICAO24 transponder hex, not by flight
 * number, so resolving a leg is two steps: list departures from the origin around
 * the scheduled time and pick the one whose ATC callsign matches, then ask for
 * that airframe's track at a moment during the flight.
 */
object OpenSkyClient {

    private const val TOKEN_URL =
        "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
    private const val API = "https://opensky-network.org/api"

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private var token: String? = null
    private var tokenExpiresAt: Instant = Instant.EPOCH

    class OpenSkyException(message: String) : IOException(message)

    /** Positions plus the day they were flown — an earlier day when borrowed for a future leg. */
    data class FetchedTrack(val points: List<TrackPoint>, val flownOn: LocalDate)

    suspend fun fetchTrack(flight: Flight): FetchedTrack = withContext(Dispatchers.IO) {
        val callsign = flight.callsign
            ?: throw OpenSkyException("No ATC callsign known for ${flight.flightNumber}")
        val origin = flight.departureAirport
            ?: throw OpenSkyException("Unknown departure airport ${flight.departure}")
        val destination = flight.arrivalAirport
            ?: throw OpenSkyException("Unknown arrival airport ${flight.arrival}")
        val scheduled = flight.departureInstant
            ?: throw OpenSkyException("No departure time for ${flight.flightNumber}")

        val bearer = accessToken()

        when (flight.phase) {
            // Airborne now: the flights endpoints only list finished flights, and
            // adsb.lol's live lookup (LivePositionClient) resolves the callsign to
            // its hex far more simply than OpenSky's own bounding-box scan of every
            // live state vector did.
            FlightPhase.IN_PROGRESS -> {
                val hex = LivePositionClient.position(callsign)?.hex
                    ?: throw OpenSkyException(
                        "$callsign is not in the live picture right now. Either no " +
                                "receiver can hear it, or it is not actually in the air."
                    )
                // Only this flight's own fixes: until OpenSky picks it up again
                // after take-off, its latest track is the leg that brought it in.
                val start = flight.trackStart ?: scheduled
                val points = fetchPath(bearer, hex, at = 0).filter { p -> p.time?.let { !it.isBefore(start) } ?: true }
                if (points.size < 2) throw OpenSkyException(
                    "OpenSky hasn't picked up ${flight.flightNumber} since take-off yet; its latest track is the aircraft's previous flight."
                )
                return@withContext FetchedTrack(points, Instant.now().atZone(origin.zone).toLocalDate())
            }

            // Flown: its own day. Future: the most recent day this callsign left the
            // same airport - airlines fly the same routing day after day.
            FlightPhase.PAST, FlightPhase.UPCOMING -> {
                val days: List<Instant> = if (flight.phase == FlightPhase.PAST) listOf(scheduled)
                else (1..7L).map { minOf(scheduled, Instant.now()).minus(Duration.ofDays(it)) }

                val seenFromAirline = linkedSetOf<String>()
                val checked = mutableListOf<String>()
                for (day in days) {
                    checked += day.atZone(origin.zone).toLocalDate().toString().substring(5)
                    val found = findFlight(
                        bearer, callsign, origin, destination, day,
                        flight.durationMinutes, seenFromAirline
                    ) ?: continue
                    val (icao24, firstSeen, lastSeen) = found
                    val flownOn = Instant.ofEpochSecond(firstSeen).atZone(origin.zone).toLocalDate()
                    return@withContext FetchedTrack(
                        fetchPath(bearer, icao24, at = (firstSeen + lastSeen) / 2),
                        flownOn
                    )
                }

                val where = "${origin.iata} departures, ${destination.iata} arrivals and the global list"
                val hint = if (seenFromAirline.isEmpty())
                    " No ${callsign.takeWhile { it.isLetter() }} flight at all was seen there."
                else " Same-airline callsigns it did see: ${seenFromAirline.take(6).joinToString()}."
                throw OpenSkyException(
                    if (flight.phase == FlightPhase.UPCOMING)
                        "OpenSky has no $callsign in $where on ${checked.first()}–${checked.last()}." +
                                hint + " Coverage relies on volunteer receivers."
                    else
                        "OpenSky has no $callsign in $where on ${checked.first()}." +
                                hint + " Its history only reaches back about 30 days."
                )
            }
        }
    }

    /**
     * Resolves a finished flight to its airframe. Three lists, cheapest and most
     * specific first: departures at the origin, arrivals at the destination (a flight
     * out of a thinly covered airport is often only caught landing somewhere dense),
     * then the global list in two-hour slices for the cases where OpenSky could not
     * guess either airport.
     */
    private fun findFlight(
        bearer: String,
        callsign: String,
        origin: Airport,
        destination: Airport,
        departAround: Instant,
        durationMinutes: Int,
        seenFromAirline: MutableSet<String>
    ): Triple<String, Long, Long>? {
        val prefix = callsign.takeWhile { it.isLetter() }

        fun pick(body: String?): Triple<String, Long, Long>? {
            val entries = body?.let { JSONArray(it).asObjects() } ?: return null
            entries.map { it.optString("callsign").trim() }
                .filter { it.startsWith(prefix) && it.isNotEmpty() }
                .forEach(seenFromAirline::add)
            // OpenSky's estimated airports are guesses; callsign plus the list we
            // asked for already pins the flight down.
            val match = entries.firstOrNull { sameCallsign(it.optString("callsign"), callsign) }
                ?: return null
            return Triple(match.getString("icao24"), match.getLong("firstSeen"), match.getLong("lastSeen"))
        }

        // Departures drift from schedule; -3h/+6h covers a long delay.
        val begin = departAround.minus(Duration.ofHours(3)).epochSecond
        val end = departAround.plus(Duration.ofHours(6)).epochSecond
        pick(getJson("$API/flights/departure?airport=${origin.icao}&begin=$begin&end=$end", bearer))
            ?.let { return it }

        // Arrivals land a flight-time later; stretch the window by the block time.
        val arrivalEnd = end + durationMinutes * 60L + 3600
        pick(getJson("$API/flights/arrival?airport=${destination.icao}&begin=$begin&end=$arrivalEnd", bearer))
            ?.let { return it }

        // Global fallback, capped at 2 h per call: the slice around schedule, then the
        // one after it for a late departure.
        for (offsetHours in listOf(-1L, 1L)) {
            val b = departAround.plus(Duration.ofHours(offsetHours)).epochSecond
            val e = b + 2 * 3600
            pick(getJson("$API/flights/all?begin=$b&end=$e", bearer))?.let { return it }
        }
        return null
    }

    /** The current live state for one already-known airframe -- cheap (a
     * single icao24 filter), meant to run alongside adsb.lol every poll:
     * each source misses a real fraction of the time (confirmed live -- an
     * aircraft adsb.lol was seeing seconds earlier came back `states: null`
     * here), so whichever one answers on a given cycle covers for the
     * other. null for any failure (network, auth, or genuinely no coverage
     * right now) -- always best-effort, never thrown, since a missed poll
     * from one source is routine, not an error. */
    suspend fun liveState(icao24: String): LivePosition? = withContext(Dispatchers.IO) {
        val bearer = runCatching { accessToken() }.getOrNull() ?: return@withContext null
        val body = runCatching { getJson("$API/states/all?icao24=${icao24.lowercase()}", bearer) }.getOrNull()
            ?: return@withContext null
        val states = runCatching { JSONObject(body).optJSONArray("states") }.getOrNull() ?: return@withContext null
        if (states.length() == 0) return@withContext null
        val v = states.getJSONArray(0)
        if (v.length() <= 10 || v.isNull(5) || v.isNull(6)) return@withContext null
        val heading = if (v.isNull(10)) 0.0 else v.getDouble(10)
        val altMeters = if (v.isNull(7)) null else v.getDouble(7)
        val lastContact = if (v.isNull(4)) null else v.getLong(4)
        LivePosition(
            lat = v.getDouble(6), lon = v.getDouble(5), heading = heading,
            altitudeFeet = altMeters?.let { (it * 3.28084).toInt() }, hex = icao24,
            seenAt = lastContact?.let { Instant.ofEpochSecond(it) } ?: Instant.now()
        )
    }

    /** A first fix for a callsign whose hex isn't known yet -- OpenSky's own
     * live state scanned inside the route's bounding box, the same way the
     * old (removed) bounding-box scan used to work for every poll. More
     * expensive than the icao24-filtered lookup above, so only meant to run
     * once, to learn the hex -- adsb.lol's own direct callsign lookup gets
     * first try, this is only the fallback when that one comes up empty. */
    suspend fun liveState(callsign: String, origin: Airport, destination: Airport): LivePosition? =
        withContext(Dispatchers.IO) {
            val bearer = runCatching { accessToken() }.getOrNull() ?: return@withContext null
            val pad = 4.0
            val lamin = minOf(origin.latitude, destination.latitude) - pad
            val lamax = maxOf(origin.latitude, destination.latitude) + pad
            val lomin = minOf(origin.longitude, destination.longitude) - pad
            val lomax = maxOf(origin.longitude, destination.longitude) + pad
            val body = runCatching {
                getJson("$API/states/all?lamin=$lamin&lomin=$lomin&lamax=$lamax&lomax=$lomax", bearer)
            }.getOrNull() ?: return@withContext null
            val states = runCatching { JSONObject(body).optJSONArray("states") }.getOrNull() ?: return@withContext null
            for (i in 0 until states.length()) {
                val v = states.getJSONArray(i)
                if (v.length() <= 10 || v.isNull(0) || v.isNull(1) || v.isNull(5) || v.isNull(6)) continue
                if (!sameCallsign(v.getString(1), callsign)) continue
                val heading = if (v.isNull(10)) 0.0 else v.getDouble(10)
                val altMeters = if (v.isNull(7)) null else v.getDouble(7)
                val lastContact = if (v.isNull(4)) null else v.getLong(4)
                return@withContext LivePosition(
                    lat = v.getDouble(6), lon = v.getDouble(5), heading = heading,
                    altitudeFeet = altMeters?.let { (it * 3.28084).toInt() }, hex = v.getString(0),
                    seenAt = lastContact?.let { Instant.ofEpochSecond(it) } ?: Instant.now()
                )
            }
            null
        }

    /** OpenSky pads callsigns to eight characters and some carriers zero-pad the number. */
    private fun sameCallsign(seen: String, wanted: String): Boolean {
        fun norm(s: String): String {
            val t = s.trim().uppercase()
            val letters = t.takeWhile { it.isLetter() }
            val digits = t.drop(letters.length).takeWhile { it.isDigit() }.trimStart('0')
            return letters + digits
        }
        return norm(seen) == norm(wanted) && norm(wanted).isNotEmpty()
    }

    /** Positions for one airframe; `at = 0` means the track of the flight it is on now. */
    private fun fetchPath(bearer: String, icao24: String, at: Long): List<TrackPoint> {
        val track = getJson("$API/tracks/all?icao24=$icao24&time=$at", bearer)
            ?: throw OpenSkyException(
                "OpenSky matched the aircraft ($icao24) but kept no track for that flight."
            )
        val path = JSONObject(track).optJSONArray("path")
            ?: throw OpenSkyException("OpenSky returned a track with no positions.")

        return (0 until path.length())
            .map { path.getJSONArray(it) }
            .filter { !it.isNull(1) && !it.isNull(2) }
            .map {
                // path[0] is the point's own Unix time.
                val time = if (!it.isNull(0)) Instant.ofEpochSecond(it.getDouble(0).toLong()) else null
                TrackPoint(lat = it.getDouble(1), lon = it.getDouble(2), time = time)
            }
            .also { if (it.size < 2) throw OpenSkyException("Track too short to draw.") }
    }

    /** The same airframe's most recently completed flight before some point in
     * time -- "this plane flew in from X about N hours ago" material. Purely a
     * courtesy note: never treated as a source of truth the way a real flight's
     * own facts are, and it's fine for this to come back null (no ADS-B
     * history, or it was already on the ground for a while beforehand). */
    data class PreviousFlight(val fromICAO: String?, val toICAO: String?, val landedAt: Instant)

    suspend fun previousFlight(icao24: String, before: Instant): PreviousFlight? = withContext(Dispatchers.IO) {
        val bearer = accessToken()
        val begin = before.epochSecond - 18 * 3600
        val end = before.epochSecond
        val body = getJson("$API/flights/aircraft/$icao24?begin=$begin&end=$end", bearer) ?: return@withContext null
        val entries = runCatching { JSONArray(body).asObjects() }.getOrNull() ?: return@withContext null
        if (entries.isEmpty()) return@withContext null
        val last = entries.filter { it.has("lastSeen") && !it.isNull("lastSeen") }
            .maxByOrNull { it.getLong("lastSeen") } ?: return@withContext null
        fun icao(key: String) = last.optString(key).takeIf { last.has(key) && !last.isNull(key) && it.isNotBlank() }
        PreviousFlight(
            fromICAO = icao("estDepartureAirport"),
            toICAO = icao("estArrivalAirport"),
            landedAt = Instant.ofEpochSecond(last.getLong("lastSeen"))
        )
    }

    private fun accessToken(): String {
        token?.let { if (Instant.now().isBefore(tokenExpiresAt)) return it }

        val id = BuildConfig.OPENSKY_CLIENT_ID
        val secret = BuildConfig.OPENSKY_CLIENT_SECRET
        if (id.isBlank() || secret.isBlank()) {
            throw OpenSkyException(
                "OpenSky credentials missing — add opensky.clientId and " +
                        "opensky.clientSecret to local.properties and rebuild."
            )
        }

        val request = Request.Builder()
            .url(TOKEN_URL)
            .post(
                FormBody.Builder()
                    .add("grant_type", "client_credentials")
                    .add("client_id", id)
                    .add("client_secret", secret)
                    .build()
            )
            .build()

        http.newCall(request).execute().use { response ->
            if (response.code == 401 || response.code == 400) {
                throw OpenSkyException("OpenSky rejected the client credentials.")
            }
            if (!response.isSuccessful) {
                throw OpenSkyException("OpenSky sign-in failed (HTTP ${response.code}).")
            }
            val body = JSONObject(response.body?.string().orEmpty())
            val access = body.getString("access_token")
            // Renew a minute early so a call never straddles expiry.
            val ttl = body.optLong("expires_in", 1800) - 60
            token = access
            tokenExpiresAt = Instant.now().plusSeconds(ttl)
            return access
        }
    }

    /** Response body, or null when OpenSky simply has nothing for that query (404). */
    private fun getJson(url: String, bearer: String): String? {
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $bearer")
            .build()
        http.newCall(request).execute().use { response ->
            when {
                response.code == 404 -> return null
                response.code == 429 -> throw OpenSkyException(
                    "OpenSky rate limit reached for today. Try again later."
                )
                !response.isSuccessful -> throw OpenSkyException(
                    "OpenSky request failed (HTTP ${response.code})."
                )
            }
            return response.body?.string().orEmpty()
        }
    }

    private fun JSONArray.asObjects(): List<JSONObject> =
        (0 until length()).map { getJSONObject(it) }
}
