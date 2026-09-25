package com.airadar.app.data

import android.content.Context
import org.json.JSONArray
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The cities a route passes, as airport codes along its great circle — dots on
 * the detail sheet's route line. Same bundled list and rules as iOS's
 * RouteAirports.swift: the world's large and medium airports with scheduled
 * service (OurAirports, public domain), offline; a city with several airports
 * reads as its IATA city code (HND, NRT -> TYO); no airport near, no dot. In
 * Chinese a stop reads as its city's name (TYO -> 东京), from the bundled table.
 */
object RouteAirports {
    /** [fraction]: how far along the route, 0 at departure, 1 at arrival. */
    data class Stop(val fraction: Double, val code: String) {
        /** What the line shows: the city's name in the app's language, else the code. */
        val name: String get() = if (L10n.chinese) zhNames[code] ?: code else code
    }

    @Volatile private var zhNames: Map<String, String> = emptyMap()

    private class Entry(val iata: String, val lat: Double, val lon: Double, val large: Boolean, val metro: String)

    @Volatile private var entries: List<Entry> = emptyList()
    @Volatile private var loaded = false
    private val memo = HashMap<String, List<Stop>>()

    /** Reads the bundled asset once; cheap after the first call. */
    fun ensureLoaded(context: Context) {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            entries = try {
                val rows = JSONArray(context.assets.open("route_airports.json").bufferedReader().use { it.readText() })
                (0 until rows.length()).map { i ->
                    val r = rows.getJSONArray(i)
                    Entry(r.getString(0), r.getDouble(1), r.getDouble(2), r.getInt(3) == 1, r.optString(4))
                }
            } catch (_: Exception) {
                emptyList()
            }
            zhNames = try {
                val table = org.json.JSONObject(context.assets.open("route_names_zh.json").bufferedReader().use { it.readText() })
                table.keys().asSequence().associateWith { table.getString(it) }
            } catch (_: Exception) {
                emptyMap()
            }
            loaded = true
        }
    }

    /** At most five stops, in order along the route. */
    fun along(from: Airport, to: Airport): List<Stop> = synchronized(this) {
        memo.getOrPut("${from.iata}-${to.iata}") { compute(from, to) }
    }

    private fun compute(a: Airport, b: Airport): List<Stop> {
        val r = Math.PI / 180
        val p1 = unit(a.latitude * r, a.longitude * r)
        val p2 = unit(b.latitude * r, b.longitude * r)
        val total = acos(dot(p1, p2).coerceIn(-1.0, 1.0))
        if (total <= 0) return emptyList()
        val km = total * 6371
        // Near enough to count as "passing over": wider for a longer flight.
        val reach = maxOf(120.0, minOf(160.0, km * 0.05))
        val normal = normalize(cross(p1, p2))

        class Candidate(val entry: Entry, val fraction: Double, val off: Double)
        val candidates = entries.filter { it.iata != a.iata && it.iata != b.iata }.mapNotNull { e ->
            val p = unit(e.lat * r, e.lon * r)
            val d = dot(p, normal)
            val off = abs(asin(d.coerceIn(-1.0, 1.0))) * 6371
            if (off > reach) return@mapNotNull null
            // Where along the route it falls: the angle from departure to its foot on the great circle.
            val foot = normalize(sub(p, scale(normal, d)))
            val along = acos(dot(p1, foot).coerceIn(-1.0, 1.0))
            if (dot(cross(p1, foot), normal) < 0) return@mapNotNull null   // behind the departure
            val fraction = along / total
            // Not the departure or arrival city itself, nor its neighbour.
            if (fraction <= 0.04 || fraction >= 0.96 || along * 6371 <= 90 || (total - along) * 6371 <= 90) return@mapNotNull null
            Candidate(e, fraction, off)
        }.sortedWith(compareBy({ if (it.entry.large) 0 else 1 }, { it.off }))

        // Large airports first, then the closest to the line; spaced out, one per city.
        val picked = mutableListOf<Stop>()
        for (c in candidates) {
            if (picked.size >= 5) break
            val code = c.entry.metro.ifEmpty { c.entry.iata }
            if (picked.any { it.code == code || abs(it.fraction - c.fraction) < 0.12 }) continue
            picked += Stop(c.fraction, code)
        }
        return picked.sortedBy { it.fraction }
    }

    private fun unit(lat: Double, lon: Double) = doubleArrayOf(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    private fun dot(a: DoubleArray, b: DoubleArray) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    private fun cross(a: DoubleArray, b: DoubleArray) =
        doubleArrayOf(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    private fun sub(a: DoubleArray, b: DoubleArray) = doubleArrayOf(a[0] - b[0], a[1] - b[1], a[2] - b[2])
    private fun scale(a: DoubleArray, k: Double) = doubleArrayOf(a[0] * k, a[1] * k, a[2] * k)
    private fun normalize(a: DoubleArray): DoubleArray {
        val n = sqrt(dot(a, a))
        return if (n > 0) scale(a, 1 / n) else a
    }
}
