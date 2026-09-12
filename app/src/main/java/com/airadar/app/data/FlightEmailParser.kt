package com.airadar.app.data

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Pulls flight numbers and dates out of a booking confirmation. Airlines all write
 * these differently, so the parser looks for the two things every confirmation
 * carries — a flight designator and a date near it — and confirms the pair against
 * the schedule table.
 */
object FlightEmailParser {

    private val flightNumber = Regex(
        """\b([A-Z]{2}|[A-Z]\d|\d[A-Z])\s?(\d{1,4})\b"""
    )

    private val isoDate = Regex("""\b(\d{4})-(\d{2})-(\d{2})\b""")
    private val slashDate = Regex("""\b(\d{1,2})/(\d{1,2})/(\d{4})\b""")
    private val namedDate = Regex(
        """\b(\d{1,2})\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{4})\b""",
        RegexOption.IGNORE_CASE
    )
    private val namedDateFirst = Regex(
        """\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+(\d{1,2}),?\s+(\d{4})\b""",
        RegexOption.IGNORE_CASE
    )

    /** Words that look like flight numbers but never are. */
    private val decoys = setOf("PNR", "ID", "NO", "REF", "TEL", "FAX", "VAT", "PO", "PIN")

    /**
     * Every flight number paired with every date in the text (a confirmation
     * lists a handful of each; the timetable check later throws out the pairs
     * that never flew). [fallbackDates] stand in when the text has no date —
     * a calendar event's own day, say.
     */
    fun candidates(text: String, fallbackDates: List<LocalDate> = emptyList()): List<Candidate> {
        val upper = text.uppercase(Locale.ROOT)
        val dates = extractDates(text).ifEmpty { fallbackDates }
        if (dates.isEmpty()) return emptyList()

        return flightNumber.findAll(upper)
            .map { it.groupValues[1] + it.groupValues[2] }
            .filterNot { code -> decoys.any { code.startsWith(it) } }
            // Two letters plus a bare "1" or "12" is far more often a gate or a seat.
            .filter { code -> code.filter(Char::isDigit).length >= 2 || code.length >= 4 }
            .distinct()
            .flatMap { code -> dates.asSequence().map { Candidate(code, it) } }
            .distinct()
            .toList()
    }

    private fun extractDates(text: String): List<LocalDate> {
        val found = mutableListOf<LocalDate>()

        isoDate.findAll(text).forEach { m ->
            runCatching {
                LocalDate.of(
                    m.groupValues[1].toInt(),
                    m.groupValues[2].toInt(),
                    m.groupValues[3].toInt()
                )
            }.getOrNull()?.let(found::add)
        }

        // Day-first, matching how most of the world writes a booking date.
        slashDate.findAll(text).forEach { m ->
            runCatching {
                LocalDate.of(
                    m.groupValues[3].toInt(),
                    m.groupValues[2].toInt(),
                    m.groupValues[1].toInt()
                )
            }.getOrNull()?.let(found::add)
        }

        val dayMonth = DateTimeFormatter.ofPattern("d MMM yyyy", Locale.ENGLISH)
        namedDate.findAll(text).forEach { m ->
            val text2 = "${m.groupValues[1]} ${m.groupValues[2].take(3)} ${m.groupValues[3]}"
            runCatching { LocalDate.parse(titleCase(text2), dayMonth) }
                .getOrNull()?.let(found::add)
        }
        namedDateFirst.findAll(text).forEach { m ->
            val text2 = "${m.groupValues[2]} ${m.groupValues[1].take(3)} ${m.groupValues[3]}"
            runCatching { LocalDate.parse(titleCase(text2), dayMonth) }
                .getOrNull()?.let(found::add)
        }

        return found.distinct()
    }

    private fun titleCase(value: String): String = value.split(" ").joinToString(" ") { part ->
        if (part.isNotEmpty() && part[0].isLetter())
            part[0].uppercase() + part.drop(1).lowercase()
        else part
    }
}
