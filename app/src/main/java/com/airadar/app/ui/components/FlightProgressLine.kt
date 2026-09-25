package com.airadar.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.HorizontalAlignmentLine
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.RouteAirports

private val Green = Color(0xFF33B34D)
private val Blue = Color(0xFF0B6FD4)

/**
 * The line between the two airport codes: an arrow before departure; in the air
 * a dashed line, the flown share green with the plane at its head; a full line
 * once landed (blue, as a finished trip's route is). Cities along the way sit on
 * it as dots with their airport (or city) code above, as many codes as fit;
 * once passed, a dot grows and it and its code turn green.
 */
@Composable
fun FlightProgressLine(flight: Flight, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val stops = remember(flight.departure, flight.arrival) {
        val a = flight.departureAirport
        val b = flight.arrivalAirport
        if (a == null || b == null) emptyList() else {
            RouteAirports.ensureLoaded(context)
            RouteAirports.along(a, b)
        }
    }
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val ring = MaterialTheme.colorScheme.surfaceContainerLow
    val phase = flight.phase
    val flown = when (phase) {
        FlightPhase.PAST -> 1.0
        FlightPhase.IN_PROGRESS -> flight.fractionFlown
        FlightPhase.UPCOMING -> 0.0
    }
    val tint = if (phase == FlightPhase.PAST) Blue else Green
    val lineY = 31.dp

    BoxWithConstraints(modifier.height(40.dp).codeLineAt(lineY)) {
        val span: Dp = maxWidth - 8.dp
        Canvas(Modifier.fillMaxSize()) {
            val y = lineY.toPx()
            val end = size.width
            val stroke = 1.5.dp.toPx()
            if (phase == FlightPhase.UPCOMING) {
                drawLine(muted, Offset(0f, y), Offset(end - 4.dp.toPx(), y), stroke)
                val tip = Offset(end - 2.dp.toPx(), y)
                drawLine(muted, tip, Offset(tip.x - 6.dp.toPx(), y - 4.dp.toPx()), stroke * 1.3f)
                drawLine(muted, tip, Offset(tip.x - 6.dp.toPx(), y + 4.dp.toPx()), stroke * 1.3f)
            } else {
                val lineEnd = end - 8.dp.toPx()
                drawLine(
                    muted.copy(alpha = 0.5f), Offset(0f, y), Offset(lineEnd, y), stroke,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))
                )
                drawLine(tint, Offset(0f, y), Offset(lineEnd * flown.toFloat(), y), 2.dp.toPx())
                drawCircle(muted, 3.dp.toPx(), Offset(end - 4.dp.toPx(), y))
            }
            val spanPx = span.toPx()
            for (stop in stops) {
                val center = Offset(spanPx * stop.fraction.toFloat(), y)
                if (stop.fraction <= flown) {
                    // Ringed so a passed dot still reads on the green line it sits on.
                    drawCircle(ring, 5.5.dp.toPx(), center)
                    drawCircle(Green, 4.dp.toPx(), center)
                } else {
                    drawCircle(muted, 2.5.dp.toPx(), center)
                }
            }
        }
        if (phase == FlightPhase.IN_PROGRESS) {
            Icon(
                Icons.Filled.Flight, contentDescription = null, tint = tint,
                modifier = Modifier
                    .offset(x = span * flown.toFloat() - 7.dp, y = lineY - 7.dp)
                    .size(14.dp)
                    .rotate(90f)
            )
        }
        var lastX = (-1000).dp
        var lastHalf = 0.dp
        for (stop in stops) {
            val x = span * stop.fraction.toFloat()
            // Each label needs its own width clear of the last: codes pack closer than city names.
            val half = labelWidth(stop.name) / 2
            if (x - lastX < lastHalf + half + 4.dp) continue
            lastX = x
            lastHalf = half
            Text(
                stop.name,
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                textAlign = TextAlign.Center,
                color = if (stop.fraction <= flown) Green else muted,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.offset(x = x - half - 2.dp, y = lineY - 20.dp).width(half * 2 + 4.dp)
            )
        }
    }
}

/** Roughly how wide a 9sp label draws: CJK characters full width, the rest monospaced. */
private fun labelWidth(label: String): Dp = label.sumOf { if (it.code >= 0x2E80) 9.5 else 5.6 }.dp

/** The middle of the big airport codes, which the route line between them sits on. */
val CodeLine = HorizontalAlignmentLine(::minOf)

/** Marks [CodeLine] this far down the view. */
fun Modifier.codeLineAt(y: Dp): Modifier = layout { measurable, constraints ->
    val p = measurable.measure(constraints)
    layout(p.width, p.height, mapOf(CodeLine to y.roundToPx())) { p.place(0, 0) }
}

/** Marks [CodeLine] through the middle of the view. */
fun Modifier.codeLineAtCenter(): Modifier = layout { measurable, constraints ->
    val p = measurable.measure(constraints)
    layout(p.width, p.height, mapOf(CodeLine to p.height / 2)) { p.place(0, 0) }
}

/**
 * Three views in a row: the two outer ones given the same width (the wider one's,
 * up to 40% of the row), the middle one the rest, centred on the row — all lined
 * up on [CodeLine], however many lines each side runs to.
 */
@Composable
fun BalancedRow(modifier: Modifier = Modifier, spacing: Dp = 10.dp, content: @Composable () -> Unit) {
    Layout(content, modifier) { measurables, constraints ->
        val width = constraints.maxWidth
        val gap = spacing.roundToPx()
        val side = minOf(
            (width * 0.4f).toInt(),
            maxOf(measurables[0].maxIntrinsicWidth(Constraints.Infinity), measurables[2].maxIntrinsicWidth(Constraints.Infinity))
        )
        val middleWidth = (width - 2 * side - 2 * gap).coerceAtLeast(0)
        val left = measurables[0].measure(Constraints(maxWidth = side))
        val middle = measurables[1].measure(Constraints.fixedWidth(middleWidth))
        val right = measurables[2].measure(Constraints(maxWidth = side))
        val placed = listOf(left, middle, right)
        val lines = placed.map { p -> p[CodeLine].takeIf { it != AlignmentLine.Unspecified } ?: (p.height / 2) }
        val line = lines.max()
        val tops = lines.map { line - it }
        val height = placed.indices.maxOf { tops[it] + placed[it].height }
        layout(width, height) {
            left.place(0, tops[0])
            middle.place((width - middleWidth) / 2, tops[1])
            right.place(width - right.width, tops[2])
        }
    }
}
