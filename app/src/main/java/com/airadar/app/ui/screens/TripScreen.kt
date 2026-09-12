package com.airadar.app.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightPhase
import com.airadar.app.ui.components.FlightDetailSheet
import com.airadar.app.ui.components.PendingFlightSheet
import com.airadar.app.ui.components.ShownTime
import com.airadar.app.ui.components.shownTime
import com.airadar.app.ui.components.formatDuration
import com.airadar.app.ui.components.label
import com.airadar.app.ui.theme.statusColor
import com.airadar.app.ui.viewmodel.TripViewModel
import kotlin.math.roundToInt

private val RefreshThreshold = 64.dp
private val HistoryThreshold = 128.dp
private val IndicatorSize = 64.dp

@Composable
fun TripScreen(
    viewModel: TripViewModel,
    forceSystemZone: Boolean,
    onCommitted: (Flight) -> Unit,
    modifier: Modifier = Modifier
) {
    // Seed from the live value, not an empty list: the first composition is what
    // fixes the list's starting index, and it has to already know the trips.
    val flights by viewModel.flights.observeAsState(viewModel.flights.value.orEmpty())
    val showHistory by viewModel.showHistory.observeAsState(false)
    val isRefreshing by viewModel.isRefreshing.observeAsState(false)

    val density = LocalDensity.current
    val refreshPx = with(density) { RefreshThreshold.toPx() }
    val historyPx = with(density) { HistoryThreshold.toPx() }
    val indicatorPx = with(density) { IndicatorSize.toPx() }

    var pull by remember { mutableFloatStateOf(0f) }
    // Held by id: the sheet must see the refreshed Flight once a track is stored on it.
    var selectedId by remember { mutableStateOf<String?>(null) }
    val trackStatus by viewModel.trackStatus.observeAsState(emptyMap())

    // Oldest first, so scrolling up walks further back in time.
    val past = remember(flights) {
        flights.filter { it.phase == FlightPhase.PAST }.sortedBy { it.departureInstant }
    }
    val airborne = remember(flights) { flights.filter { it.phase == FlightPhase.IN_PROGRESS } }
    val coming = remember(flights) {
        flights.filter { it.phase == FlightPhase.UPCOMING }.sortedBy { it.departureInstant }
    }

    // Past trips always occupy the top of the list — the viewport simply starts
    // below them. Nothing is inserted or removed, so the rows never jump.
    val anchorIndex = if (past.isEmpty()) 0 else past.size + 1
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = anchorIndex)
    val locked = rememberUpdatedState(!showHistory)

    // Keep the viewport on the present if the number of past trips changes.
    var settledAnchor by remember { mutableIntStateOf(anchorIndex) }
    LaunchedEffect(anchorIndex) {
        if (anchorIndex != settledAnchor) {
            if (!showHistory) listState.scrollToItem(anchorIndex)
            settledAnchor = anchorIndex
        }
    }

    LaunchedEffect(showHistory, anchorIndex) {
        if (!showHistory || past.isEmpty()) return@LaunchedEffect
        // Close once every past card has scrolled off the top — waiting for the
        // thin divider to clear as well would feel like nothing happened.
        // Locking again is only right after the traveller has actually been up
        // there; otherwise the unlock would undo itself on the very first frame.
        var visitedPast = false
        snapshotFlow { listState.firstVisibleItemIndex }.collect { index ->
            if (index < past.size) visitedPast = true
            else if (visitedPast) viewModel.hideHistory()
        }
    }

    LaunchedEffect(viewModel.resetSignal) {
        listState.animateScrollToItem(anchorIndex)
    }

    val nestedScroll = remember(listState, anchorIndex) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                // Unwind any accumulated pull before the list itself moves.
                if (available.y < 0 && pull > 0f) {
                    val consumed = -minOf(pull, -available.y)
                    pull += consumed
                    return Offset(0f, consumed)
                }
                // While the past is closed the list cannot travel above the
                // present; that drag becomes the pull gesture instead.
                if (locked.value && available.y > 0 && listState.restingAt(anchorIndex)) {
                    pull = (pull + available.y * 0.5f).coerceAtMost(historyPx * 1.4f)
                    return available
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                val released = pull
                if (released <= 0f) return Velocity.Zero
                pull = 0f
                when {
                    released >= historyPx -> viewModel.revealHistory()
                    released >= refreshPx -> viewModel.refresh()
                }
                return available
            }
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .nestedScroll(nestedScroll)
    ) {
        PullIndicator(
            pull = pull,
            refreshPx = refreshPx,
            historyPx = historyPx,
            isRefreshing = isRefreshing,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset { IntOffset(0, (pull - indicatorPx).roundToInt()) }
        )

        LazyColumn(
            state = listState,
            // The list slides down with the drag so the indicator is revealed
            // above it instead of covering the first card.
            modifier = Modifier
                .fillMaxSize()
                .offset { IntOffset(0, pull.roundToInt()) },
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            if (past.isNotEmpty()) {
                flightItems(past, forceSystemZone, dimmed = true) { selectedId = it.id }
                item(key = "past-divider") { TimeDivider() }
            }

            // "Now" marks the present: either flights in the air, or simply the
            // boundary between what has been flown and what is ahead.
            if (airborne.isNotEmpty()) {
                item(key = "now-header") { SectionTitle("Now") }
                flightItems(airborne, forceSystemZone) { selectedId = it.id }
                item(key = "coming-divider") { TimeDivider() }
                item(key = "coming-header") { SectionTitle("Coming") }
            } else {
                item(key = "coming-header") {
                    Crossfade(
                        targetState = if (showHistory) "Now" else "Coming",
                        label = "sectionTitle"
                    ) { title -> SectionTitle(title) }
                }
            }

            flightItems(coming, forceSystemZone) { selectedId = it.id }

            if (coming.isEmpty() && airborne.isEmpty()) {
                item(key = "empty") {
                    Text(
                        "No upcoming trips. Pull down to refresh.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 24.dp)
                    )
                }
            }
        }
    }

    selectedId?.let { id ->
        val flight = flights.firstOrNull { it.id == id } ?: return@let
        if (flight.isPending) {
            PendingFlightSheet(
                flight = flight,
                onConfirm = {
                    viewModel.confirmPending(it)
                    onCommitted(it)
                    selectedId = null
                },
                onReplace = { old, replacement ->
                    viewModel.replacePending(old, replacement)
                    onCommitted(replacement)
                    selectedId = null
                },
                onDismiss = { selectedId = null }
            )
        } else {
            FlightDetailSheet(
                flight = flight,
                forceSystemZone = forceSystemZone,
                trackStatus = trackStatus[flight.id],
                onLoadTrack = { viewModel.loadTrack(flight) },
                onDismiss = { selectedId = null }
            )
        }
    }
}

private fun LazyListScope.flightItems(
    flights: List<Flight>,
    forceSystemZone: Boolean,
    dimmed: Boolean = false,
    onSelect: (Flight) -> Unit
) {
    items(flights, key = { it.id }) { flight ->
        FlightCard(
            flight = flight,
            forceSystemZone = forceSystemZone,
            dimmed = dimmed,
            onClick = { onSelect(flight) }
        )
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.headlineMedium,
        modifier = Modifier.padding(top = 4.dp, bottom = 4.dp)
    )
}

@Composable
private fun TimeDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(vertical = 6.dp),
        thickness = 1.dp,
        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)
    )
}

@Composable
private fun PullIndicator(
    pull: Float,
    refreshPx: Float,
    historyPx: Float,
    isRefreshing: Boolean,
    modifier: Modifier = Modifier
) {
    if (pull <= 1f && !isRefreshing) return

    // A full turn of the icon marks the refresh point; keep pulling past it and
    // releasing opens the history above.
    val rotation by animateFloatAsState(
        targetValue = (pull / refreshPx) * 360f,
        label = "pullRotation"
    )

    Column(
        modifier = modifier.height(IndicatorSize),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Box(
            modifier = Modifier
                .size(32.dp)
                .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(16.dp)),
            contentAlignment = Alignment.Center
        ) {
            if (isRefreshing) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.primary
                )
            } else {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = null,
                    modifier = Modifier
                        .size(18.dp)
                        .rotate(rotation),
                    tint = MaterialTheme.colorScheme.primary
                )
            }
        }

        val hint = when {
            isRefreshing -> "Refreshing"
            pull >= historyPx -> "Release to open past trips"
            pull >= refreshPx -> "Release to refresh · keep pulling for history"
            else -> "Pull to refresh"
        }
        Text(
            hint,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp)
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlightCard(
    flight: Flight,
    forceSystemZone: Boolean,
    onClick: () -> Unit,
    dimmed: Boolean = false,
    modifier: Modifier = Modifier
) {
    val shape = RoundedCornerShape(14.dp)
    val dashed = flight.isPending

    Card(
        // Card's own onClick keeps the ripple and the hit target on the card
        // itself, rather than layering a tap handler behind decoration modifiers.
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .then(
                // An imported trip stays dashed until the traveller confirms it.
                if (dashed) Modifier.dashedBorder(
                    color = MaterialTheme.colorScheme.primary,
                    shape = shape
                ) else Modifier
            ),
        colors = CardDefaults.cardColors(
            containerColor = when {
                dashed -> MaterialTheme.colorScheme.surface
                dimmed -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
                else -> MaterialTheme.colorScheme.surface
            }
        ),
        shape = shape,
        elevation = CardDefaults.cardElevation(
            defaultElevation = if (dimmed || dashed) 0.dp else 1.dp
        )
    ) {
        Column(modifier = Modifier.padding(14.dp)) {

            if (dashed) {
                Text(
                    "Imported · needs review",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(bottom = 8.dp)
                )
            }

            // Row 1 — airline and flight number
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    flight.airlineName.ifBlank { "—" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    flight.flightNumber,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            }

            Spacer(Modifier.height(10.dp))

            // Row 2 — departure: city + country, airport, terminal · time + zone
            AirportRow(
                city = flight.departureAirport?.let { "${it.city}, ${it.countryCode}" },
                code = flight.departure,
                terminal = flight.departureTerminal,
                time = flight.shownTime(arrival = false, forceSystemZone = forceSystemZone)
            )

            Spacer(Modifier.height(6.dp))

            // Row 3 — arrival, same layout
            AirportRow(
                city = flight.arrivalAirport?.let { "${it.city}, ${it.countryCode}" },
                code = flight.arrival,
                terminal = flight.arrivalTerminal,
                time = flight.shownTime(arrival = true, forceSystemZone = forceSystemZone)
            )

            Spacer(Modifier.height(10.dp))

            // Row 4 — status and typical duration
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .background(
                            flight.status.statusColor().copy(alpha = 0.14f),
                            RoundedCornerShape(6.dp)
                        )
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                ) {
                    Text(
                        buildString {
                            append(flight.status.label())
                            if (flight.delayMinutes > 0) append(" ${flight.delayMinutes}m")
                        },
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = flight.status.statusColor()
                    )
                }

                Text(
                    "Usually ${formatDuration(flight.typicalDurationMinutes ?: flight.durationMinutes)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private fun Modifier.dashedBorder(color: Color, shape: Shape) = drawWithContent {
    drawContent()
    drawOutline(
        outline = shape.createOutline(size, layoutDirection, this),
        color = color,
        style = Stroke(
            width = 1.5.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 8f))
        )
    )
}

@Composable
private fun AirportRow(city: String?, code: String, terminal: String?, time: ShownTime) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Bottom
        ) {
            // Code and terminal read as one token, in the same weight.
            Text(
                if (terminal != null) "$code T$terminal" else code,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )
            Row(
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.padding(start = 8.dp)
            ) {
                Text(
                    time.clock,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium
                )
                if (time.zoneTag.isNotEmpty()) {
                    Text(
                        " ${time.zoneTag}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(bottom = 1.dp)
                    )
                }
            }
        }
        city?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/** True while the list sits at (or above) the present, with nothing left to unscroll. */
private fun LazyListState.restingAt(anchor: Int): Boolean =
    firstVisibleItemIndex < anchor ||
            (firstVisibleItemIndex == anchor && firstVisibleItemScrollOffset == 0)
