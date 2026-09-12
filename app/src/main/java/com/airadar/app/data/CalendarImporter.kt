package com.airadar.app.data

import android.content.Context
import android.provider.CalendarContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/**
 * Flights already sitting in the phone's calendars — airline apps, Gmail and
 * TripIt all drop them there. Needs READ_CALENDAR. The event's own day stands in
 * when its text carries a flight number but no date.
 */
object CalendarImporter {

    suspend fun scan(context: Context): List<Candidate> = withContext(Dispatchers.IO) {
        val now = Instant.now()
        val from = now.minus(365, ChronoUnit.DAYS).toEpochMilli()
        val to = now.plus(365, ChronoUnit.DAYS).toEpochMilli()

        val projection = arrayOf(
            CalendarContract.Events.TITLE,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.EVENT_TIMEZONE
        )
        val found = mutableListOf<Candidate>()
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ? AND ${CalendarContract.Events.DELETED} = 0",
            arrayOf(from.toString(), to.toString()),
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val text = listOf(cursor.getString(0), cursor.getString(1), cursor.getString(2))
                    .filterNotNull().joinToString("\n")
                if (text.isBlank()) continue
                val start = cursor.getLong(3)
                val zone = cursor.getString(4)?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: ZoneId.systemDefault()
                val day: LocalDate = Instant.ofEpochMilli(start).atZone(zone).toLocalDate()
                found += FlightEmailParser.candidates(text, fallbackDates = listOf(day))
            }
        }
        found.distinct()
    }
}
