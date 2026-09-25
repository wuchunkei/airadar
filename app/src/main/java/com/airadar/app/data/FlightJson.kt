package com.airadar.app.data

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeParseException

/** The trip document as the server stores it — the same names as [Flight]. */
fun Flight.toJson(): JSONObject = JSONObject().apply {
    put("id", id)
    put("flightNumber", flightNumber)
    put("airlineName", airlineName)
    put("departure", departure)
    put("arrival", arrival)
    put("departureTerminal", departureTerminal ?: JSONObject.NULL)
    put("arrivalTerminal", arrivalTerminal ?: JSONObject.NULL)
    put("departureGate", departureGate ?: JSONObject.NULL)
    put("arrivalGate", arrivalGate ?: JSONObject.NULL)
    put("departureTime", departureTime.toString())
    put("arrivalTime", arrivalTime.toString())
    put("status", status.name)
    put("aircraft", aircraft ?: JSONObject.NULL)
    put("baggageClaim", baggageClaim ?: JSONObject.NULL)
    put("delayMinutes", delayMinutes)
    put("arrivalDelayMinutes", arrivalDelayMinutes ?: JSONObject.NULL)
    put("boardingStatus", boardingStatus?.name ?: JSONObject.NULL)
    put("callsign", callsign ?: JSONObject.NULL)
    put("pnr", pnr ?: JSONObject.NULL)
    put("isPending", isPending)
    put("isManual", isManual)
    put("feedStatus", feedStatus?.name?.lowercase() ?: JSONObject.NULL)
    put("importedVia", importedVia ?: JSONObject.NULL)
    if (passengers.isNotEmpty()) put("passengers", JSONArray().apply { passengers.forEach { put(it) } })
    // A third element, when a point has a time, is its own Unix timestamp --
    // added after the wire format shipped, so an older point without one
    // just stays a plain [lat, lon] pair.
    put("track", track?.let { points ->
        JSONArray().apply {
            points.forEach { p ->
                val row = JSONArray().put(p.lat).put(p.lon)
                p.time?.let { row.put(it.epochSecond.toDouble()) }
                put(row)
            }
        }
    } ?: JSONObject.NULL)
    put("trackFlownOn", trackFlownOn?.toString() ?: JSONObject.NULL)
}

fun flightFromJson(o: JSONObject): Flight = Flight(
    id = o.getString("id"),
    flightNumber = o.getString("flightNumber"),
    airlineName = o.optString("airlineName"),
    departure = o.getString("departure"),
    arrival = o.getString("arrival"),
    departureTerminal = o.text("departureTerminal"),
    arrivalTerminal = o.text("arrivalTerminal"),
    departureGate = o.text("departureGate"),
    arrivalGate = o.text("arrivalGate"),
    departureTime = LocalDateTime.parse(o.getString("departureTime").take(19)),
    arrivalTime = LocalDateTime.parse(o.getString("arrivalTime").take(19)),
    status = runCatching { FlightStatus.valueOf(o.optString("status")) }.getOrDefault(FlightStatus.SCHEDULED),
    aircraft = o.text("aircraft"),
    baggageClaim = o.text("baggageClaim"),
    delayMinutes = o.optInt("delayMinutes", 0),
    arrivalDelayMinutes = if (o.isNull("arrivalDelayMinutes")) null else o.optInt("arrivalDelayMinutes"),
    boardingStatus = BoardingStatus.from(o.text("boardingStatus")),
    callsign = o.text("callsign"),
    pnr = o.text("pnr"),
    isPending = o.optBoolean("isPending", false),
    isManual = o.optBoolean("isManual", false),
    feedStatus = o.text("feedStatus")?.let { runCatching { FeedStatus.valueOf(it.uppercase()) }.getOrNull() },
    importedVia = o.text("importedVia"),
    passengers = o.optJSONArray("passengers")?.let { arr ->
        (0 until arr.length()).map { arr.getString(it) }
    } ?: emptyList(),
    track = o.optJSONArray("track")?.let { arr ->
        (0 until arr.length()).map { i ->
            val p = arr.getJSONArray(i)
            val time = if (p.length() >= 3) java.time.Instant.ofEpochSecond(p.getDouble(2).toLong()) else null
            TrackPoint(p.getDouble(0), p.getDouble(1), time)
        }
    },
    trackFlownOn = o.text("trackFlownOn")?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() },
    deletedAt = o.text("deletedAt")?.let { raw ->
        try {
            OffsetDateTime.parse(raw).toInstant()
        } catch (_: DateTimeParseException) {
            // A naive timestamp from the server is UTC.
            runCatching { LocalDateTime.parse(raw.take(19)).atOffset(ZoneOffset.UTC).toInstant() }.getOrNull()
        }
    }
)

fun personFromJson(o: JSONObject): Person =
    Person(o.getString("id"), o.optString("givenName").ifBlank { "Friend" }, o.optString("color").ifBlank { "#1E88E5" })

fun shareFromJson(o: JSONObject): TripShare? {
    val person = o.optJSONObject("person")?.let(::personFromJson) ?: return null
    val status = runCatching { ShareStatus.valueOf(o.optString("status").uppercase()) }.getOrNull() ?: return null
    return TripShare(o.getString("id"), person, status)
}

fun friendFromJson(o: JSONObject): Friend = Friend(
    o.getString("friendshipId"),
    personFromJson(o.getJSONObject("person")),
    runCatching { FriendStatus.valueOf(o.optString("status").uppercase()) }.getOrDefault(FriendStatus.OUTGOING)
)

private fun JSONObject.text(key: String): String? =
    optString(key).takeIf { has(key) && !isNull(key) && it.isNotBlank() && it != "null" }
