package com.airadar.app.data

import android.content.Context
import java.io.File
import java.time.Instant
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/** Every active airline IATA-coded worldwide, bundled once from OpenFlights'
 * long-standing public dataset (github.com/jpatokal/openflights) — free, no
 * network needed, works offline. It is not live: OpenFlights itself is only
 * occasionally updated, so a very recently renamed or newly launched carrier
 * may be missing or out of date. That's what "Other" and a suggestion are
 * for — see [AirlineSuggestionStore]. Same bundled JSON as iOS's own copy. */
data class AirlineInfo(val name: String, val iata: String, val icao: String, val country: String)

object AirlineDatabase {
    private var byIata: Map<String, AirlineInfo> = emptyMap()
    private var all: List<AirlineInfo> = emptyList()
    @Volatile private var loaded = false

    /** Reads the bundled asset once; safe to call repeatedly, cheap after the first time. */
    fun ensureLoaded(context: Context) {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            all = try {
                val text = context.assets.open("airlines.json").bufferedReader().use { it.readText() }
                val array = JSONArray(text)
                (0 until array.length()).map { i ->
                    val o = array.getJSONObject(i)
                    AirlineInfo(
                        name = o.optString("name"),
                        iata = o.optString("iata").uppercase(Locale.ROOT),
                        icao = o.optString("icao"),
                        country = o.optString("country")
                    )
                }
            } catch (_: Exception) {
                emptyList()
            }
            byIata = all.associateBy { it.iata }
            loaded = true
        }
    }

    fun airline(iata: String): AirlineInfo? = byIata[iata.uppercase(Locale.ROOT)]

    /** Up to [limit] airlines whose name or IATA code matches [query] — an
     * exact code match first, then by name, alphabetically. Empty for a blank query. */
    fun search(query: String, limit: Int = 20): List<AirlineInfo> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        val upper = q.uppercase(Locale.ROOT)
        val byCode = all.filter { it.iata == upper }
        val byName = all.filter { it.iata != upper && it.name.contains(q, ignoreCase = true) }
            .sortedBy { it.name.lowercase(Locale.ROOT) }
        return (byCode + byName).take(limit)
    }
}

/** A traveller's own correction — an airline the bundled table doesn't have,
 * or has wrong — staged on this device until there is somewhere real to send
 * it. TODO once the backend has a pending-approval endpoint and SMTP is
 * configured: POST these and have the server mail the admin to review each
 * one; for now they just sit here so nothing is lost. */
data class AirlineSuggestion(val id: String, val flightNumber: String, val suggestedName: String, val createdAt: Instant)

object AirlineSuggestionStore {
    private lateinit var cacheFile: File
    private var pending: MutableList<AirlineSuggestion> = mutableListOf()
    @Volatile private var initialized = false

    private fun ensureInit(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            cacheFile = File(context.filesDir, "airline-suggestions.json")
            pending = try {
                if (cacheFile.exists()) {
                    val array = JSONArray(cacheFile.readText())
                    (0 until array.length()).map { i ->
                        val o = array.getJSONObject(i)
                        AirlineSuggestion(
                            id = o.optString("id"),
                            flightNumber = o.optString("flightNumber"),
                            suggestedName = o.optString("suggestedName"),
                            createdAt = runCatching { Instant.parse(o.optString("createdAt")) }.getOrDefault(Instant.now())
                        )
                    }.toMutableList()
                } else mutableListOf()
            } catch (_: Exception) {
                mutableListOf()
            }
            initialized = true
        }
    }

    fun submit(context: Context, flightNumber: String, name: String) {
        ensureInit(context)
        pending.add(AirlineSuggestion(UUID.randomUUID().toString(), flightNumber, name, Instant.now()))
        val snapshot = pending.toList()
        runCatching {
            val array = JSONArray()
            snapshot.forEach { s ->
                array.put(JSONObject().apply {
                    put("id", s.id)
                    put("flightNumber", s.flightNumber)
                    put("suggestedName", s.suggestedName)
                    put("createdAt", s.createdAt.toString())
                })
            }
            cacheFile.writeText(array.toString())
        }
    }
}
