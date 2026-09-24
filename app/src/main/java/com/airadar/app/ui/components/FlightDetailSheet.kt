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
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.airadar.app.data.FlightStore
import com.airadar.app.data.LivePosition
import com.airadar.app.data.LivePositionClient
import com.airadar.app.data.TrackPoint
import com.airadar.app.data.OpenSkyClient
import com.airadar.app.data.formatDistance
import com.airadar.app.ui.theme.statusColor
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlightDetailSheet(
    flight: Flight,
    onDismiss: () -> Unit,
    forceSystemZone: Boolean = false,
    onLoadTrack: (() -> Unit)? = null,
    primaryAction: Pair<String, () -> Unit>? = null,
    /** Extra buttons under the itinerary — share, accept, together, and so on. */
    extraActions: (@Composable () -> Unit)? = null
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
            // Where the aircraft actually is right now (ADS-B), asked every
            // 5 minutes while the flight is in the air -- the same source
            // (adsb.lol) the pulsing dot on My's own map uses.
            var live by remember(flight.id) { mutableStateOf<LivePosition?>(null) }
            // Every live fix collected this way since the sheet opened -- a
            // real, if short, breadcrumb trail for a flight OpenSky's own
            // track fetch hasn't (yet, or ever) answered for. Genuinely
            // reported positions, never the schedule's own estimate --
            // that's what the plain arc with a progress cut is for, and
            // only shown while this stays too short to draw on its own.
            val liveTrail = remember(flight.id) { mutableStateListOf<TrackPoint>() }
            // Learned once (from whichever of adsb.lol/OpenSky answers
            // first) and kept for the rest of this session, so OpenSky's own
            // live lookup can use its cheap icao24 filter on every later
            // poll instead of the bounding-box scan finding it the first
            // time needs.
            var knownHex by remember(flight.id) { mutableStateOf<String?>(null) }
            if (flight.phase == FlightPhase.IN_PROGRESS && flight.callsign != null) {
                LaunchedEffect(flight.id, flight.callsign) {
                    while (isActive) {
                        // adsb.lol and OpenSky polled together once the hex is
                        // known (each misses a real fraction of the time;
                        // whichever answers on a given cycle covers for the
                        // other), adsb.lol alone tried first while it isn't,
                        // OpenSky's own bounding-box scan only as the
                        // fallback to learn it at all.
                        val hex = knownHex
                        val fix = if (hex != null) {
                            coroutineScope {
                                val fromAdsbLol = async { LivePositionClient.position(flight.callsign) }
                                val fromOpenSky = async { OpenSkyClient.liveState(hex) }
                                fromAdsbLol.await() ?: fromOpenSky.await()
                            }
                        } else {
                            LivePositionClient.position(flight.callsign) ?: run {
                                val origin = flight.departureAirport
                                val destination = flight.arrivalAirport
                                if (origin != null && destination != null) {
                                    OpenSkyClient.liveState(flight.callsign, origin, destination)
                                } else null
                            }
                        }
                        if (fix != null) {
                            live = fix
                            if (knownHex == null) knownHex = fix.hex
                            val last = liveTrail.lastOrNull()
                            if (last == null || last.lat != fix.lat || last.lon != fix.lon) {
                                liveTrail.add(TrackPoint(fix.lat, fix.lon, fix.seenAt))
                                // Every real fix earns its keep on the server, not
                                // just in this sheet's own memory -- otherwise the
                                // whole trail is lost the moment the sheet closes
                                // or the app is relaunched. Stored on the trip
                                // itself (not a separate collection), so it
                                // survives a soft delete and is purged with the
                                // trip -- the recycle bin's own 30-day TTL, no
                                // extra retention logic of its own.
                                val storedTrack = flight.track
                                val lastStored = if (storedTrack != null)
                                    storedTrack.mapNotNull { it.time }.maxOrNull() else null
                                val trail = if (storedTrack != null && storedTrack.isNotEmpty()) {
                                    storedTrack + liveTrail.filter {
                                        (it.time ?: java.time.Instant.MIN).isAfter(lastStored ?: java.time.Instant.MIN)
                                    }
                                } else liveTrail.toList()
                                FlightStore.setTrack(flight.id, trail, flight.departureTime.toLocalDate())
                            }
                        }
                        delay(300_000)
                    }
                }
            }

            val from = flight.departureAirport
            val to = flight.arrivalAirport
            if (from != null && to != null) {
                // The actual reported points to draw, if there are any yet --
                // the downloaded historical track once OpenSky has answered,
                // or (until then, or if it never does) this session's own
                // live-polled breadcrumb trail. Only when neither exists does
                // the plain arc with a progress cut take over.
                // A flight that hasn't departed always shows the plain arc,
                // never a track -- even a stale one stored from before this
                // rule existed.
                val storedTrack = flight.track
                val realTrack = when {
                    flight.phase == FlightPhase.UPCOMING -> null
                    storedTrack != null && storedTrack.size >= 2 -> {
                        // The one-time historical fetch on its own goes stale
                        // the moment it lands (trackFlownOn turning non-null
                        // stops it from ever being asked for again) -- so for
                        // a flight still in the air, whatever this session's
                        // own live poll has collected SINCE the stored
                        // track's own last point is appended, keeping the
                        // line itself growing all the way from departure to
                        // right now, not just the plane marker (which
                        // livePlane already refreshes on its own regardless).
                        val lastStored = if (flight.phase == FlightPhase.IN_PROGRESS)
                            storedTrack.mapNotNull { it.time }.maxOrNull() else null
                        if (lastStored != null) {
                            storedTrack + liveTrail.filter { (it.time ?: java.time.Instant.MIN).isAfter(lastStored) }
                        } else storedTrack
                    }
                    liveTrail.size >= 2 -> liveTrail.toList()
                    else -> null
                }?.let { gapFilled(it) }
                val progress = if (realTrack == null && flight.phase == FlightPhase.IN_PROGRESS) flight.fractionFlown else null
                // Ticks once a minute in the air, so the map's estimated position moves on.
                val minute by produceState(java.time.Instant.now(), flight.id) {
                    while (flight.phase == FlightPhase.IN_PROGRESS) { delay(60_000); value = java.time.Instant.now() }
                }
                val eta = flight.expectedArrival
                TileMap(
                    routes = if (realTrack == null) listOf(MapRoute(from, to, progress = progress)) else emptyList(),
                    tracks = if (realTrack == null) emptyList()
                    else listOf(
                        MapTrack(
                            from, to, realTrack, live = flight.phase == FlightPhase.IN_PROGRESS,
                            eta = eta, now = if (flight.phase == FlightPhase.IN_PROGRESS) minute else null,
                        )
                    ),
                    interactive = false,
                    livePlane = live,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(mapHeight)
                        .padding(horizontal = 16.dp)
                        .clip(RoundedCornerShape(16.dp))
                )
            }

            // OpenSky gets the first shot at a real track -- quietly, the same
            // way it always has, no button and no caption: this fires exactly
            // once per flight (LaunchedEffect only restarts when flight.id
            // changes), and flight.trackFlownOn turning non-null on success is
            // what stops it from ever asking twice.
            if (onLoadTrack != null && flight.callsign != null && flight.trackFlownOn == null &&
                flight.phase != FlightPhase.UPCOMING
            ) {
                LaunchedEffect(flight.id) { onLoadTrack() }
            }

            // Where this same airframe flew in from, if OpenSky's own
            // per-aircraft history has anything recent -- a courtesy note,
            // not a fact this trip itself carries. Only attempted once a
            // live hex is actually known.
            var previousFlight by remember(flight.id) { mutableStateOf<OpenSkyClient.PreviousFlight?>(null) }
            LaunchedEffect(live?.hex) {
                val hex = live?.hex ?: return@LaunchedEffect
                previousFlight = runCatching {
                    OpenSkyClient.previousFlight(hex, flight.departureInstant ?: java.time.Instant.now())
                }.getOrNull()
            }

            Column(modifier = Modifier.padding(horizontal = 20.dp, vertical = 16.dp)) {
                previousFlight?.fromICAO?.let { from ->
                    Text(
                        "Landed from $from ${relativeAgo(previousFlight!!.landedAt)}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 8.dp)
                    )
                }
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
                            flight.statusLine(),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                            color = flight.displayStatus.statusColor()
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
                // The arrival moves on its own figure once the source has one, early or late.
                val arrMoved = flight.arrivalDelayMinutes?.let { it != 0 } ?: late
                val depScheduled = flight.shownTime(arrival = false, forceSystemZone = forceSystemZone)
                val arrScheduled = flight.shownTime(arrival = true, forceSystemZone = forceSystemZone)
                val depActual = flight.shownTime(arrival = false, forceSystemZone = forceSystemZone, includeDelay = late)
                val arrActual = flight.shownTime(arrival = true, forceSystemZone = forceSystemZone, includeDelay = arrMoved)
                DetailRow(
                    label = "Departing",
                    value = "${depActual.clock} ${depActual.zoneTag}".trim(),
                    superseded = if (late) depScheduled.clock else null,
                    secondary = flight.departureTime.format(dateFormat)
                )
                DetailRow(
                    label = "Arriving",
                    value = "${arrActual.clock} ${arrActual.zoneTag}".trim(),
                    superseded = if (arrMoved) arrScheduled.clock else null,
                    early = arrMoved && flight.arrivalShiftMinutes < 0,
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

                // Who shared it, when the trip is a friend's.
                flight.sharedBy?.let { share ->
                    DetailRow(label = "Shared by", value = share.person.givenName, secondary = share.status.label())
                }

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

                extraActions?.let { actions ->
                    Column(modifier = Modifier.padding(top = 16.dp)) { actions() }
                }
            }
        }
    }
}


@Composable
private fun DetailRow(
    label: String,
    value: String,
    secondary: String? = null,
    /** An earlier figure this value replaced — shown struck through beside it. */
    superseded: String? = null,
    /** The new figure is earlier than the one it replaced: green, not the delay colour. */
    early: Boolean = false
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
                    // A revised time reads in the delay colour, or on-time green when earlier.
                    color = when {
                        superseded == null -> MaterialTheme.colorScheme.onSurface
                        early -> FlightStatus.ON_TIME.statusColor()
                        else -> FlightStatus.DELAYED.statusColor()
                    }
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

/** "3h ago", "12m ago" -- coarse on purpose, this is a courtesy note, not a clock. */
/** Bridges a gap between two consecutive real points with a bowed arc
 * instead of a straight line -- confirmed a real, not hypothetical, need:
 * OpenSky's own historical track for a genuinely airborne aircraft, tested
 * live, had a 9.7-minute hole where every position call came back empty. A
 * gap wider than 2.5x the 5-minute poll interval means neither live source
 * answered for at least one whole cycle -- the interpolated points carry no
 * time of their own, so they're never mistaken for another real fix by
 * anything reading them. */
private fun gapFilled(points: List<TrackPoint>): List<TrackPoint> {
    if (points.size < 2) return points
    val out = mutableListOf(points[0])
    for (i in 1 until points.size) {
        val prev = points[i - 1]
        val next = points[i]
        val t1 = prev.time
        val t2 = next.time
        if (t1 != null && t2 != null && java.time.Duration.between(t1, t2).seconds > 750) {
            val bridge = arcPath(prev.lat, prev.lon, next.lat, next.lon)
            bridge.drop(1).dropLast(1).forEach { out += TrackPoint(it.latitude, it.longitude) }
        }
        out += next
    }
    return out
}

fun relativeAgo(instant: java.time.Instant): String {
    val minutes = java.time.Duration.between(instant, java.time.Instant.now()).toMinutes().coerceAtLeast(0)
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "${minutes}m ago"
        else -> "${minutes / 60}h ago"
    }
}

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
    FlightStatus.LANDED -> "Finished"
}

/**
 * The status as one line: in the air, how long it's been flying; before it goes, how late
 * it is ("late", so it can't be read as a duration); once down, how early or
 * late it landed, when the source said.
 */
fun Flight.statusLine(now: java.time.Instant = java.time.Instant.now()): String {
    val status = displayStatus.label()
    if (displayStatus == FlightStatus.CANCELLED || displayStatus == FlightStatus.DIVERTED) return status
    fun span(minutes: Long) = if (minutes >= 60) "${minutes / 60}h${minutes % 60}m" else "${minutes}m"
    return when (phase) {
        FlightPhase.IN_PROGRESS -> {
            val dep = departureInstant ?: return status
            val flown = java.time.Duration.between(dep.plusSeconds(delayMinutes * 60L), now).toMinutes()
            if (flown > 0) "$status for ${span(flown)}" else status
        }
        FlightPhase.UPCOMING -> if (delayMinutes > 0) "$status · ${span(delayMinutes.toLong())} late" else status
        FlightPhase.PAST -> {
            val d = arrivalDelayMinutes ?: return status
            when {
                d < 0 -> "Landed · ${span(-d.toLong())} early"
                d > 0 -> "Landed · ${span(d.toLong())} late"
                else -> "Landed · on time"
            }
        }
    }
}
