package com.airadar.app.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.AnchoredDraggableState
import androidx.compose.foundation.gestures.DraggableAnchors
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.anchoredDraggable
import androidx.compose.foundation.gestures.animateTo
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Surface
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import kotlinx.coroutines.launch
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import com.airadar.app.data.ShareStatus
import com.airadar.app.data.onColor
import com.airadar.app.data.sortedForDisplay
import com.airadar.app.ui.components.ShareSheet
import com.airadar.app.ui.components.blockColor
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
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.runtime.derivedStateOf
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
import androidx.compose.ui.zIndex
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
import java.time.LocalDate
import kotlin.math.roundToInt

private val RefreshThreshold = 64.dp
private val HistoryThreshold = 128.dp
private val IndicatorSize = 64.dp

@Composable
fun TripScreen(
    viewModel: TripViewModel,
    forceSystemZone: Boolean,
    onCommitted: (Flight) -> Unit,
    onDeleted: (Flight) -> Unit,
    onFriendsClick: () -> Unit,
    signedIn: Boolean,
    modifier: Modifier = Modifier
) {
    var shareFor by remember { mutableStateOf<Flight?>(null) }
    val scope = rememberCoroutineScope()
    val delete: (Flight) -> Unit = {
        viewModel.deleteFlight(it)
        onDeleted(it)
    }
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
    // The one card showing its Delete button, and where it sits on screen. Any
    // touch that lands outside it, or a scroll, shuts it again.
    var openSwipeId by remember { mutableStateOf<String?>(null) }
    val openSwipeBounds = remember { mutableStateOf<Rect?>(null) }
    val swipe = SwipeCoordinator(openSwipeId, { openSwipeId = it }, openSwipeBounds)
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

    // A short present — one trip ahead, say — cannot be scrolled to the top on
    // its own: the list has nothing below it to fill the screen, so it rests
    // with history showing above. A tail spacer makes up exactly the missing
    // height, no more, so the present section always reaches the top and the
    // list never scrolls into empty space beyond it.
    val spacingPx = with(density) { 10.dp.roundToPx() }
    val tailHeightPx by remember(anchorIndex) {
        derivedStateOf {
            val info = listState.layoutInfo
            val tailIndex = info.totalItemsCount - 1
            val present = info.visibleItemsInfo.filter { it.index >= anchorIndex && it.index < tailIndex }
            val lastPresentVisible = present.any { it.index == tailIndex - 1 }
            if (!lastPresentVisible) 0
            else {
                val viewport = info.viewportEndOffset - info.viewportStartOffset
                (viewport - present.sumOf { it.size } - spacingPx * present.size).coerceAtLeast(0)
            }
        }
    }
    LaunchedEffect(listState) {
        // Once the tail has grown, the present can finally sit at the top: put it there.
        snapshotFlow { tailHeightPx }.collect {
            if (it > 0 && locked.value && listState.firstVisibleItemIndex < anchorIndex) {
                listState.scrollToItem(anchorIndex)
            }
        }
    }

    LaunchedEffect(showHistory, anchorIndex) {
        if (!showHistory || past.isEmpty()) return@LaunchedEffect
        // Open only by the over-pull; closed again the moment the traveller scrolls
        // the present back to the top — that is, when the Coming/Now heading is the
        // first thing on screen. Locking again is only right after they have
        // actually been up in the past; otherwise the unlock would undo itself on
        // the very first frame.
        var visitedPast = false
        snapshotFlow { listState.firstVisibleItemIndex }.collect { index ->
            if (index < anchorIndex) visitedPast = true
            else if (visitedPast) {
                viewModel.hideHistory()
                // Settle exactly on the heading, not a few pixels past it.
                listState.animateScrollToItem(anchorIndex)
            }
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

    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }.collect { if (it) openSwipeId = null }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .nestedScroll(nestedScroll)
            .pointerInput(Unit) {
                // Watched on the initial pass so nothing downstream can swallow it,
                // and never consumed, so taps and drags carry on as normal.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    if (openSwipeId != null && openSwipeBounds.value?.contains(down.position) != true) {
                        openSwipeId = null
                    }
                }
            }
    ) {
        // Friends, where My keeps Settings: top right, over the list.
        Surface(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(16.dp)
                .size(44.dp)
                .zIndex(1f),
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
            tonalElevation = 3.dp
        ) {
            IconButton(onClick = onFriendsClick) {
                Icon(Icons.Outlined.People, contentDescription = "Friends", tint = MaterialTheme.colorScheme.onSurface)
            }
        }

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
                flightItems(past, forceSystemZone, dimmed = true, onDelete = delete, swipe = swipe) { selectedId = it.id }
                item(key = "past-divider") { TimeDivider() }
            }

            // "Now" marks the present: either flights in the air, or simply the
            // boundary between what has been flown and what is ahead.
            if (airborne.isNotEmpty()) {
                item(key = "now-header") { SectionTitle("Now") }
                // Now is today by definition; no heading needed.
                flightItems(airborne, forceSystemZone, dateHeadings = false, onDelete = delete, swipe = swipe) { selectedId = it.id }
                item(key = "coming-divider") { TimeDivider() }
                item(key = "coming-header") { SectionTitle("Coming") }
            } else {
                // "Now" only when a flight departs today; otherwise what is ahead is "Coming".
                val flyingToday = coming.any { it.departureTime.toLocalDate() == LocalDate.now() }
                item(key = "coming-header") {
                    Crossfade(
                        targetState = if (flyingToday) "Now" else "Coming",
                        label = "sectionTitle"
                    ) { title -> SectionTitle(title) }
                }
            }

            flightItems(coming, forceSystemZone, onDelete = delete, swipe = swipe) { selectedId = it.id }

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

            // Always the last item; see tailHeightPx.
            item(key = "tail") {
                Spacer(Modifier.height(with(density) { tailHeightPx.toDp() }))
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
            val share = flight.sharedBy
            // A friend's trip: answer it.
            val respondActions: @Composable () -> Unit = {
                RespondButtons(share?.status ?: ShareStatus.PENDING) { action ->
                    selectedId = null
                    scope.launch { runCatching { viewModel.respondToShare(flight, action) } }
                    if (action != "reject") onCommitted(flight)
                }
            }
            // My own: offer it.
            val shareActions: @Composable () -> Unit = {
                OutlinedButton(
                    onClick = { shareFor = flight },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(50.dp),
                    shape = RoundedCornerShape(10.dp)
                ) {
                    Icon(Icons.Outlined.Share, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("Share", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp))
                }
            }
            FlightDetailSheet(
                flight = flight,
                forceSystemZone = forceSystemZone,
                trackStatus = trackStatus[flight.id],
                onLoadTrack = { viewModel.loadTrack(flight) },
                onDismiss = { selectedId = null },
                extraActions = when {
                    share != null && share.status != ShareStatus.TOGETHER -> respondActions
                    signedIn && !flight.isPending -> shareActions
                    else -> null
                }
            )
        }
    }

    shareFor?.let { ShareSheet(flight = it, onDismiss = { shareFor = null }) }
}

/** Accept (green) · Together (yellow) · Reject (red); an accepted trip can still be taken together. */
@Composable
private fun RespondButtons(status: ShareStatus, onRespond: (String) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        if (status == ShareStatus.PENDING) {
            Button(
                onClick = { onRespond("accept") },
                colors = ButtonDefaults.buttonColors(containerColor = ShareStatus.ACCEPTED.blockColor(), contentColor = Color.White),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp),
                shape = RoundedCornerShape(10.dp)
            ) { Text("Accept", fontWeight = FontWeight.SemiBold) }
        }
        if (status != ShareStatus.TOGETHER) {
            Button(
                onClick = { onRespond("together") },
                colors = ButtonDefaults.buttonColors(containerColor = ShareStatus.TOGETHER.blockColor(), contentColor = Color(0xFF111111)),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp),
                shape = RoundedCornerShape(10.dp)
            ) { Text("Together", fontWeight = FontWeight.SemiBold) }
        }
        if (status == ShareStatus.PENDING) {
            Button(
                onClick = { onRespond("reject") },
                colors = ButtonDefaults.buttonColors(containerColor = ShareStatus.REJECTED.blockColor(), contentColor = Color.White),
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp),
                shape = RoundedCornerShape(10.dp)
            ) { Text("Reject", fontWeight = FontWeight.SemiBold) }
        }
    }
}

private fun LazyListScope.flightItems(
    flights: List<Flight>,
    forceSystemZone: Boolean,
    dimmed: Boolean = false,
    dateHeadings: Boolean = true,
    onDelete: (Flight) -> Unit,
    swipe: SwipeCoordinator,
    onSelect: (Flight) -> Unit
) {
    // The date heading lives inside the first card's item of each day rather than
    // as an item of its own, so item counts — which the history anchor is built
    // on — stay one per flight.
    itemsIndexed(flights, key = { _, it -> it.id }) { index, flight ->
        val day = flight.departureTime.toLocalDate()
        val firstOfDay = dateHeadings &&
                (index == 0 || flights[index - 1].departureTime.toLocalDate() != day)
        Column {
            if (firstOfDay) DateTitle(day.toString(), dimmed)
            val folded = remember(flight.id) { mutableStateOf(false) }
            CompositionLocalProvider(LocalShareListExpanded provides folded) {
                SwipeToDelete(
                    isOpen = swipe.openId == flight.id,
                    onOpened = { swipe.open(flight.id) },
                    onBounds = { if (swipe.openId == flight.id) swipe.bounds.value = it },
                    onDelete = { onDelete(flight) }
                ) {
                    FlightCard(
                        flight = flight,
                        forceSystemZone = forceSystemZone,
                        dimmed = dimmed,
                        onClick = { onSelect(flight) }
                    )
                }
            }
        }
    }
}

private enum class Reveal { CLOSED, OPEN }

/** Which card is swiped open, shared by every section of the list. */
private class SwipeCoordinator(
    val openId: String?,
    val open: (String) -> Unit,
    val bounds: MutableState<Rect?>
)

private val DeleteWidth = 92.dp

/**
 * Drag the card leftwards to uncover a Delete button behind it; the card snaps
 * open or shut, and a tap on the button is what actually deletes.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun SwipeToDelete(
    isOpen: Boolean,
    onOpened: () -> Unit,
    onBounds: (Rect) -> Unit,
    onDelete: () -> Unit,
    content: @Composable () -> Unit
) {
    val density = LocalDensity.current
    val openPx = with(density) { DeleteWidth.toPx() }
    val state = remember(openPx) {
        AnchoredDraggableState(
            initialValue = Reveal.CLOSED,
            positionalThreshold = { distance -> distance * 0.5f },
            velocityThreshold = { with(density) { 120.dp.toPx() } },
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioLowBouncy,
                stiffness = Spring.StiffnessMediumLow
            )
        ).apply {
            updateAnchors(DraggableAnchors {
                Reveal.CLOSED at 0f
                Reveal.OPEN at -openPx
            })
        }
    }
    val scope = rememberCoroutineScope()

    // Report the moment this card heads open, so the previously open one is told to shut.
    LaunchedEffect(state) {
        snapshotFlow { state.targetValue }.collect { if (it == Reveal.OPEN) onOpened() }
    }
    // Told to shut from outside — another card opened, a scroll, a tap elsewhere.
    LaunchedEffect(isOpen) {
        if (!isOpen && state.targetValue == Reveal.OPEN) state.animateTo(Reveal.CLOSED)
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .onGloballyPositioned { onBounds(it.boundsInRoot()) }
    ) {
        // The button fades in with the drag, so a closed card hides it completely.
        Box(
            modifier = Modifier
                .matchParentSize()
                .padding(start = 8.dp)
                .graphicsLayer { alpha = (-state.requireOffset() / openPx).coerceIn(0f, 1f) },
            contentAlignment = Alignment.CenterEnd
        ) {
            Surface(
                onClick = {
                    scope.launch { state.animateTo(Reveal.CLOSED) }
                    onDelete()
                },
                modifier = Modifier
                    .width(DeleteWidth - 8.dp)
                    .fillMaxHeight(),
                shape = RoundedCornerShape(20.dp),
                color = MaterialTheme.colorScheme.error,
                contentColor = MaterialTheme.colorScheme.onError
            ) {
                Column(
                    modifier = Modifier.fillMaxSize(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Icon(Icons.Outlined.Delete, contentDescription = null)
                    Text("Delete", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        Box(
            modifier = Modifier
                .offset { IntOffset(state.requireOffset().roundToInt(), 0) }
                .anchoredDraggable(state, Orientation.Horizontal)
        ) {
            content()
        }
    }
}

/** A day's heading over its cards: the section title's shape, at a smaller size. */
@Composable
private fun DateTitle(text: String, dimmed: Boolean) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        color = if (dimmed) MaterialTheme.colorScheme.onSurfaceVariant
        else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(top = 6.dp, bottom = 6.dp)
    )
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
    val shape = RoundedCornerShape(20.dp)
    val shared = flight.sharedBy
    // A friend's trip wears their colour; one still waiting for my answer is dashed.
    // Once taken together it is my own trip again, and only the name block remains.
    val dashed = flight.isPending || shared?.status == ShareStatus.PENDING
    val ground = shared?.takeIf { it.status != ShareStatus.TOGETHER }?.person?.tint
    val ink = ground?.onColor()
    val baseScheme = MaterialTheme.colorScheme
    val scheme = if (ground == null || ink == null) baseScheme else baseScheme.copy(
        surface = ground,
        onSurface = ink,
        onSurfaceVariant = ink.copy(alpha = 0.72f),
        primary = ink
    )

    MaterialTheme(colorScheme = scheme) {
    Card(
        // Card's own onClick keeps the ripple and the hit target on the card
        // itself, rather than layering a tap handler behind decoration modifiers.
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .then(
                // An imported trip stays dashed until the traveller confirms it.
                if (dashed) Modifier.dashedBorder(
                    color = if (ground != null) ground else MaterialTheme.colorScheme.primary,
                    shape = shape
                ) else Modifier
            ),
        colors = CardDefaults.cardColors(
            containerColor = when {
                // Waiting on my answer: the friend's colour only as an outline and a tint.
                ground != null && dashed -> ground.copy(alpha = 0.18f).compositeOver(baseScheme.surface)
                ground != null -> ground
                dashed -> MaterialTheme.colorScheme.surface
                // Composited, not translucent: nothing behind the card may show through.
                dimmed -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)
                    .compositeOver(MaterialTheme.colorScheme.background)
                else -> MaterialTheme.colorScheme.surface
            }
        ),
        shape = shape,
        elevation = CardDefaults.cardElevation(
            defaultElevation = if (dimmed || dashed) 0.dp else 1.dp
        )
    ) {
        Column(modifier = Modifier.padding(14.dp)) {

            if (dashed && shared == null) {
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

                // Who this is shared with (mine) or who shared it (theirs).
                ShareBlocks(flight, modifier = Modifier.weight(1f).padding(start = 8.dp))

                Text(
                    "Usually ${formatDuration(flight.typicalDurationMinutes ?: flight.durationMinutes)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            ShareList(flight)
        }
    }
    }
}

/**
 * Next to the status: a friend's name on a trip they shared, or a block per friend
 * I shared mine with, coloured by their answer. Past two, the rest fold behind a
 * chevron and open as a list under the card's rows.
 */
@Composable
private fun ShareBlocks(flight: Flight, modifier: Modifier = Modifier) {
    val shared = flight.sharedBy
    val outgoing = remember(flight.shares) { flight.shares.sortedForDisplay() }
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        when {
            shared != null -> NameBlock(
                shared.person.givenName,
                if (shared.status == ShareStatus.TOGETHER) shared.person.tint else MaterialTheme.colorScheme.onSurface,
                dashed = shared.status == ShareStatus.PENDING
            )
            outgoing.size <= 2 -> outgoing.forEach { NameBlock(it.person.givenName, it.status.blockColor()) }
            else -> {
                val expanded = LocalShareListExpanded.current
                NameBlock(outgoing.first().person.givenName, outgoing.first().status.blockColor())
                Box(
                    modifier = Modifier
                        .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.10f), RoundedCornerShape(6.dp))
                        .clickable { expanded.value = !expanded.value }
                        .padding(horizontal = 6.dp, vertical = 3.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "+${outgoing.size - 1}",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.SemiBold
                        )
                        Icon(
                            if (expanded.value) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }
            }
        }
    }
}

/** The folded list: every friend, name in their colour, answer on the right. */
@Composable
private fun ShareList(flight: Flight) {
    val expanded = LocalShareListExpanded.current
    if (!expanded.value || flight.shares.size <= 2) return
    Column(modifier = Modifier.padding(top = 10.dp)) {
        HorizontalDivider(color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f))
        flight.shares.sortedForDisplay().forEach { share ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    share.person.givenName,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = share.person.tint
                )
                Text(
                    share.status.label(),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = share.status.blockColor()
                )
            }
        }
    }
}

/** Whether a card's share list is unfolded; each card gets its own. */
private val LocalShareListExpanded = compositionLocalOf<MutableState<Boolean>> { mutableStateOf(false) }

@Composable
private fun NameBlock(name: String, color: Color, dashed: Boolean = false) {
    val shape = RoundedCornerShape(6.dp)
    Box(
        modifier = Modifier
            .then(if (dashed) Modifier.dashedBorder(color, shape) else Modifier.background(color.copy(alpha = 0.16f), shape))
            .padding(horizontal = 8.dp, vertical = 3.dp)
    ) {
        Text(
            name,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
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
