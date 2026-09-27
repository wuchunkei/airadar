package com.airadar.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.time.Duration
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit

/**
 * Boarding progress, gate, delay, actual times and belt from the flight boards
 * of mainland Chinese airports -- read by the phone itself, since these sites
 * only answer visitors inside mainland China (the backend, abroad, is turned
 * away). Same as iOS's ChinaAirportBoards.swift.
 *
 * Shenzhen Bao'an: the JSON behind its own departures/arrivals pages
 * (szairport.com, /szjchbjk/hbcx/flightInfo), as its airlineNew.js reads it.
 */
object ChinaAirportBoards {
    val airports = setOf("SZX")

    private val zone: ZoneId = ZoneId.of("Asia/Shanghai")
    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS)
        .build()

    /** Worth asking about: departing within about three hours, or arriving within a few hours of now. */
    fun applies(f: Flight, now: Instant = Instant.now()): Boolean {
        if (f.isManual || f.deletedAt != null) return false
        val dep = f.departureInstant ?: return false
        if (f.departure in airports &&
            now.isAfter(dep.minus(Duration.ofHours(3))) &&
            now.isBefore(dep.plus(Duration.ofMinutes(f.delayMinutes.toLong() + 120)))) return true
        val arr = f.arrivalInstant ?: return false
        return f.arrival in airports && now.isAfter(dep) && now.isBefore(arr.plus(Duration.ofHours(3)))
    }

    /** The flight with whatever the boards say applied; null when nothing new (or unreachable). */
    suspend fun update(flight: Flight, now: Instant = Instant.now()): Flight? = withContext(Dispatchers.IO) {
        var f = flight
        if (f.departure in airports) szxRow(f, "D", now)?.let { f = applyDeparture(it, f) }
        if (f.arrival in airports) szxRow(f, "A", now)?.let { f = applyArrival(it, f) }
        if (f == flight) null else f
    }

    // --- Shenzhen ---

    private fun szxRow(f: Flight, flag: String, now: Instant): JSONObject? {
        // The board keys a day as yesterday/today/tomorrow (0/1/2) on its own clock;
        // time block 12 is the whole day.
        val day = (if (flag == "D") f.departureTime else f.arrivalTime).toLocalDate()
        val diff = ChronoUnit.DAYS.between(now.atZone(zone).toLocalDate(), day)
        if (diff !in -1..1) return null
        val url = "https://www.szairport.com/szjchbjk/hbcx/flightInfo".toHttpUrl().newBuilder()
            .addQueryParameter("type", "cn").addQueryParameter("flag", flag)
            .addQueryParameter("currentDate", (diff + 1).toString()).addQueryParameter("currentTime", "12")
            .addQueryParameter("hbxx_hbh", f.flightNumber)
            .build()
        val request = Request.Builder().url(url)
            .header("Referer", "https://www.szairport.com/")
            .header("X-Requested-With", "XMLHttpRequest")
            .build()
        val body = runCatching {
            http.newCall(request).execute().use { if (it.code == 200) it.body?.string() else null }
        }.getOrNull() ?: return null
        val list = runCatching { JSONObject(body).optJSONArray("flightList") }.getOrNull() ?: return null
        val wanted = normalize(f.flightNumber)
        for (i in 0 until list.length()) {
            val row = list.optJSONObject(i) ?: continue
            val numbers = row.optJSONArray("hbh") ?: JSONArray()
            for (j in 0 until numbers.length()) {
                if (normalize(numbers.optJSONObject(j)?.optString("flightNo").orEmpty()) == wanted) return row
            }
        }
        return null
    }

    /** Status codes, "#"-separated, as the board accumulates them through the day. */
    private fun codes(row: JSONObject): Set<String> =
        row.optString("fltNormalStatus2").split("#").map { it.trim().uppercase() }.filter { it.isNotEmpty() }.toSet()

    private fun applyDeparture(row: JSONObject, flight: Flight): Flight {
        var f = flight
        val c = codes(row)
        nonEmpty(row.opt("gateCode"))?.let { gate ->
            if (gate != f.departureGate) f = f.copy(departureGate = gate, departureGatePrevious = f.departureGate ?: f.departureGatePrevious)
        }
        // The furthest boarding stage reached: 开始值机, 开始登机, 催促登机, 结束登机.
        val stage = when {
            "POK" in c -> BoardingStatus.GATE_CLOSED
            "LBD" in c -> BoardingStatus.FINAL_CALL
            "BOR" in c || "TBR" in c -> BoardingStatus.BOARDING
            "CKI" in c -> BoardingStatus.CHECK_IN
            else -> f.boardingStatus
        }
        f = f.copy(boardingStatus = stage)
        time(row.opt("startRealTakeoffTime"), f.departureTime)?.let { moved ->
            f = f.copy(delayMinutes = maxOf(0, minutes(f.departureTime, moved)))
        }
        // Never backwards: a flight already known to be in the air or down stays so.
        if (f.status in setOf(FlightStatus.IN_FLIGHT, FlightStatus.LANDED, FlightStatus.COMPLETED,
                FlightStatus.CANCELLED, FlightStatus.DIVERTED)) return f
        val status = when {
            "CAN" in c -> FlightStatus.CANCELLED
            "ALT" in c -> FlightStatus.DIVERTED
            "DEP" in c -> FlightStatus.DEPARTED
            "DLY" in c || f.delayMinutes > 0 -> FlightStatus.DELAYED
            else -> f.status
        }
        return f.copy(status = status)
    }

    private fun applyArrival(row: JSONObject, flight: Flight): Flight {
        var f = flight
        val c = codes(row)
        time(row.opt("terminalRealLandinTime"), f.arrivalTime)?.let { moved ->
            f = f.copy(arrivalDelayMinutes = minutes(f.arrivalTime, moved))
        }
        f = when {
            "ARR" in c || "NST" in c -> f.copy(status = FlightStatus.LANDED)
            "CAN" in c -> f.copy(status = FlightStatus.CANCELLED)
            "ALT" in c -> f.copy(status = FlightStatus.DIVERTED)
            else -> f
        }
        nonEmpty(row.opt("blls"))?.let { belt ->
            if (belt != f.baggageClaim) f = f.copy(baggageClaim = belt, baggageClaimPrevious = f.baggageClaim ?: f.baggageClaimPrevious)
        }
        return f
    }

    // --- Parsing ---

    private fun nonEmpty(v: Any?): String? {
        val s = (v?.takeIf { it != JSONObject.NULL } ?: return null).toString().trim()
        return if (s.isEmpty() || s == "-" || s == "--" || s == "null") null else s
    }

    /**
     * "21:35", "2026-09-27 21:35", "2026-09-27 21:35:00" or "202609272135", on
     * the day nearest the scheduled time when only a clock is given.
     */
    private fun time(v: Any?, near: LocalDateTime): LocalDateTime? {
        val s = nonEmpty(v) ?: return null
        if (s.length >= 16) runCatching { return LocalDateTime.parse(s.take(16).replace(' ', 'T')) }
        if (s.length == 12 && s.all { it.isDigit() }) runCatching {
            return LocalDateTime.of(s.take(4).toInt(), s.substring(4, 6).toInt(), s.substring(6, 8).toInt(),
                s.substring(8, 10).toInt(), s.substring(10, 12).toInt())
        }
        val clock = s.split(":")
        if (clock.size < 2) return null
        val h = clock[0].toIntOrNull() ?: return null
        val m = clock[1].take(2).toIntOrNull() ?: return null
        if (h !in 0..23 || m !in 0..59) return null
        val sameDay = near.withHour(h).withMinute(m).withSecond(0).withNano(0)
        return listOf(-1L, 0L, 1L).map { sameDay.plusDays(it) }
            .minByOrNull { kotlin.math.abs(Duration.between(near, it).toMinutes()) }
    }

    private fun minutes(a: LocalDateTime, b: LocalDateTime): Int = Duration.between(a, b).toMinutes().toInt()

    /** "HU 7744", "hu07744" -> "HU7744". */
    private fun normalize(number: String): String {
        val s = number.uppercase().filterNot { it.isWhitespace() }
        if (s.length < 3) return s
        val prefix = s.take(2)
        val rest = s.drop(2)
        val digits = rest.takeWhile { it.isDigit() }
        val n = digits.toIntOrNull() ?: return s
        return prefix + n + rest.drop(digits.length)
    }
}
