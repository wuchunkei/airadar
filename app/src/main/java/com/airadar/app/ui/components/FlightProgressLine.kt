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

    BoxWithConstraints(modifier.height(40.dp)) {
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
        for (stop in stops) {
            val x = span * stop.fraction.toFloat()
            if (x - lastX < 21.dp) continue
            lastX = x
            Text(
                stop.code,
                fontSize = 9.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                textAlign = TextAlign.Center,
                color = if (stop.fraction <= flown) Green else muted,
                modifier = Modifier.offset(x = x - 14.dp, y = lineY - 20.dp).width(28.dp)
            )
        }
    }
}
