package com.airadar.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.FlightStatus
import com.airadar.app.data.formatDistance
import com.airadar.app.ui.theme.statusColor
import com.airadar.app.ui.viewmodel.TrackStatus
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlightDetailSheet(
    flight: Flight,
    onDismiss: () -> Unit,
    forceSystemZone: Boolean = false,
    trackStatus: TrackStatus? = null,
    onLoadTrack: (() -> Unit)? = null,
    primaryAction: Pair<String, () -> Unit>? = null
) {
    // Opening fully expanded gives the whole itinerary in one look; on a tall phone
    // it fits without scrolling, and a short one simply scrolls the tail.
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val mapHeight = (LocalConfiguration.current.screenHeightDp * 0.20f).dp

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
        ) {
            val from = flight.departureAirport
            val to = flight.arrivalAirport
            if (from != null && to != null) {
                val track = flight.track
                TileMap(
                    routes = if (track == null) listOf(MapRoute(from, to)) else emptyList(),
                    tracks = if (track == null) emptyList() else listOf(MapTrack(from, to, track)),
                    interactive = false,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(mapHeight)
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(16.dp))
                )

                // Only a leg that has flown (or is flying) has a track to fetch; a
                // future one is drawn as a great circle without comment.
                if (onLoadTrack != null && flight.callsign != null && flight.phase != FlightPhase.UPCOMING) {
                    TrackLoader(
                        phase = flight.phase,
                        flownOn = flight.trackFlownOn,
                        status = trackStatus,
                        onLoad = onLoadTrack,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }
            }

            Column(modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Top
                ) {
                    Column {
                        Text(
                            flight.airlineName.ifBlank { "Airline" },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            flight.flightNumber,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text(
                            "Status",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            flight.status.label(),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = flight.status.statusColor()
                        )
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 16.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            from?.city ?: flight.departure,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            flight.departure,
                            fontSize = 36.sp,
                            fontWeight = FontWeight.Bold,
                            style = MaterialTheme.typography.displaySmall
                        )
                        flight.departureTerminal?.let {
                            Text(
                                "Terminal $it",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    Text("✈", fontSize = 26.sp, modifier = Modifier.padding(horizontal = 8.dp))

                    Column(
                        modifier = Modifier.weight(1f),
                        horizontalAlignment = Alignment.End
                    ) {
                        Text(
                            to?.city ?: flight.arrival,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            flight.arrival,
                            fontSize = 36.sp,
                            fontWeight = FontWeight.Bold,
                            style = MaterialTheme.typography.displaySmall
                        )
                        flight.arrivalTerminal?.let {
                            Text(
                                "Terminal $it",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp))

                val late = flight.status == FlightStatus.DELAYED && flight.delayMinutes > 0
                val depScheduled = flight.shownTime(arrival = false, forceSystemZone = forceSystemZone)
                val arrScheduled = flight.shownTime(arrival = true, forceSystemZone = forceSystemZone)
                val depActual = flight.shownTime(arrival = false, forceSystemZone = forceSystemZone, includeDelay = late)
                val arrActual = flight.shownTime(arrival = true, forceSystemZone = forceSystemZone, includeDelay = late)
                DetailRow(
                    label = "Departing",
                    value = "${depActual.clock} ${depActual.zoneTag}".trim(),
                    superseded = if (late) depScheduled.clock else null,
                    secondary = flight.departureTime.format(dateFormat)
                )
                DetailRow(
                    label = "Arriving",
                    value = "${arrActual.clock} ${arrActual.zoneTag}".trim(),
                    superseded = if (late) arrScheduled.clock else null,
                    secondary = flight.arrivalTime.format(dateFormat)
                )
                DetailRow(
                    label = "Duration",
                    value = formatDuration(flight.durationMinutes)
                )
                DetailRow(
                    label = "Distance",
                    value = formatDistance(flight.distanceKm)
                )
                flight.aircraft?.let { DetailRow(label = "Aircraft", value = it) }
                // Belt numbers appear close to landing; the row is always there so the
                // traveller knows where to look for it later.
                DetailRow(label = "Baggage claim", value = flight.baggageClaim ?: "–")
                flight.pnr?.let { DetailRow(label = "Booking reference", value = it) }

                primaryAction?.let { (label, action) ->
                    Button(
                        onClick = action,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 16.dp)
                            .height(50.dp),
                        shape = RoundedCornerShape(10.dp)
                    ) {
                        Text(label, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

@Composable
private fun TrackLoader(
    phase: FlightPhase,
    flownOn: LocalDate?,
    status: TrackStatus?,
    onLoad: () -> Unit,
    modifier: Modifier = Modifier
) {
    val hasTrack = flownOn != null
    Column(modifier = modifier) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                when {
                    status is TrackStatus.Loading -> "Fetching ADS-B track"
                    flownOn == null -> "Route shown as a great circle"
                    phase == FlightPhase.IN_PROGRESS -> "Showing the path flown so far"
                    else -> "Showing the path actually flown"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f, fill = false)
            )
            when (status) {
                TrackStatus.Loading -> CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp
                )
                else -> TextButton(onClick = onLoad, contentPadding = PaddingValues(horizontal = 8.dp)) {
                    Text(
                        if (hasTrack) "Reload" else "Load flown track"
                    )
                }
            }
        }
        (status as? TrackStatus.Failed)?.let {
            Text(
                it.reason,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
    }
}

@Composable
private fun DetailRow(
    label: String,
    value: String,
    secondary: String? = null,
    /** An earlier figure this value replaced — shown struck through beside it. */
    superseded: String? = null
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Column(horizontalAlignment = Alignment.End) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                superseded?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyMedium,
                        textDecoration = TextDecoration.LineThrough,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(end = 8.dp)
                    )
                }
                Text(
                    value,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    // A revised time reads in the delay colour, nothing more.
                    color = if (superseded != null) FlightStatus.DELAYED.statusColor()
                    else MaterialTheme.colorScheme.onSurface
                )
            }
            secondary?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private val dateFormat: DateTimeFormatter = DateTimeFormatter.ofPattern("EEE, d MMM", Locale.ENGLISH)

fun formatDuration(minutes: Int): String {
    if (minutes <= 0) return "—"
    val hours = minutes / 60
    val mins = minutes % 60
    return when {
        hours == 0 -> "${mins}m"
        mins == 0 -> "${hours}h"
        else -> "${hours}h ${mins}m"
    }
}

fun FlightStatus.label(): String = when (this) {
    FlightStatus.ON_TIME -> "On time"
    FlightStatus.DELAYED -> "Delayed"
    FlightStatus.CANCELLED -> "Cancelled"
    FlightStatus.DIVERTED -> "Diverted"
    FlightStatus.SCHEDULED -> "Scheduled"
    FlightStatus.COMPLETED -> "Completed"
    FlightStatus.BOARDING -> "Boarding"
    FlightStatus.DEPARTED -> "Departed"
    FlightStatus.IN_FLIGHT -> "In flight"
    FlightStatus.LANDED -> "Landed"
}
