package com.airadar.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.airadar.app.data.HomeRegion
import com.airadar.app.data.Region
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Airport
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.systemPrefersMetric
import com.airadar.app.ui.components.FlightDetailSheet
import com.airadar.app.ui.components.MapRoute
import com.airadar.app.ui.components.MapTrack
import com.airadar.app.ui.components.TileMap
import com.airadar.app.ui.components.toMapRoutes
import com.airadar.app.ui.viewmodel.TrackStatus
import com.airadar.app.ui.viewmodel.travelStats
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MyScreen(
    flights: List<Flight>,
    forceSystemZone: Boolean,
    trackStatus: Map<String, TrackStatus>,
    onLoadTrack: (Flight) -> Unit,
    onSettingsClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val history = remember(flights) {
        flights.filter { it.phase == FlightPhase.PAST && !it.isPending }
    }
    // Legs with a downloaded track are drawn as flown; the rest fall back to arcs.
    val tracks: List<MapTrack> = remember(history) {
        history.mapNotNull { flight ->
            val from = flight.departureAirport ?: return@mapNotNull null
            val to = flight.arrivalAirport ?: return@mapNotNull null
            flight.track?.let { MapTrack(from, to, it) }
        }
    }
    val routes: List<MapRoute> = remember(history) {
        history.filter { it.track == null }.toMapRoutes()
    }
    val stats = remember(history) { history.travelStats() }

    // The legs under the traveller's tap, and the flights that flew them, newest first.
    var selectedLegs by remember { mutableStateOf<List<Pair<Airport, Airport>>>(emptyList()) }
    val legFlights = remember(selectedLegs, history) {
        history
            .filter { f -> selectedLegs.any { (from, to) -> f.departure == from.iata && f.arrival == to.iata } }
            .sortedByDescending { it.departureInstant }
    }
    var openId by remember { mutableStateOf<String?>(null) }

    // With no trips yet the map has nothing to frame, so it looks at where the
    // traveller is: a coarse fix if they allow it, their country otherwise.
    val context = LocalContext.current
    var homeRegion by remember { mutableStateOf<Region?>(null) }
    val askLocation = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    LaunchedEffect(history.isEmpty()) {
        if (history.isNotEmpty()) return@LaunchedEffect
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) askLocation.launch(Manifest.permission.ACCESS_COARSE_LOCATION)
        homeRegion = HomeRegion.find(context)
    }

    Box(modifier = modifier.fillMaxSize()) {

        // Full-bleed map; pinch to zoom, drag to pan.
        TileMap(
            routes = routes,
            tracks = tracks,
            selected = selectedLegs,
            onLegsClick = { selectedLegs = it },
            onMapTap = { selectedLegs = emptyList() },
            emptyFocus = homeRegion,
            modifier = Modifier.fillMaxSize()
        )

        Surface(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(16.dp)
                .size(44.dp),
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.92f),
            tonalElevation = 3.dp
        ) {
            IconButton(onClick = onSettingsClick) {
                Icon(
                    Icons.Outlined.Settings,
                    contentDescription = "Settings",
                    tint = MaterialTheme.colorScheme.onSurface
                )
            }
        }

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
        ) {
            if (legFlights.isNotEmpty()) {
                // Same width as the stats panel below; several flights on one leg page sideways.
                val cardsState = rememberLazyListState()
                LazyRow(
                    state = cardsState,
                    flingBehavior = rememberSnapFlingBehavior(cardsState),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(horizontal = 12.dp)
                ) {
                    items(legFlights, key = { it.id }) { flight ->
                        LegCard(
                            flight,
                            onClick = { openId = flight.id },
                            modifier = Modifier.fillParentMaxWidth()
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
                tonalElevation = 6.dp
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 16.dp, horizontal = 8.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly
                ) {
                    val metric = systemPrefersMetric()
                    val distance = if (metric) stats.totalDistanceKm
                    else (stats.totalDistanceKm * 0.621371).toInt()

                    StatCell(
                        value = "%,d".format(distance),
                        unit = if (metric) "km" else "mi",
                        label = "Distance"
                    )
                    StatCell(value = "${stats.flightCount}", unit = "", label = "Flights")
                    StatCell(value = "${stats.countryCount}", unit = "", label = "Countries")
                    StatCell(value = "${stats.cityCount}", unit = "", label = "Cities")
                }
            }
        }
    }

    openId?.let { id ->
        val flight = flights.firstOrNull { it.id == id } ?: return@let
        FlightDetailSheet(
            flight = flight,
            forceSystemZone = forceSystemZone,
            trackStatus = trackStatus[flight.id],
            onLoadTrack = { onLoadTrack(flight) },
            onDismiss = { openId = null }
        )
    }
}

private val legDate: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd (EEE)", Locale.ENGLISH)

/** One flight on the tapped leg: who flew it, when, and between which airports. */
@Composable
private fun LegCard(flight: Flight, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val from = flight.departureAirport
    val to = flight.arrivalAirport
    Card(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    flight.airlineName,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false)
                )
                Text(
                    flight.flightNumber,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(start = 8.dp)
                )
            }
            Text(
                flight.departureTime.toLocalDate().format(legDate),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp)
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                LegEnd(flight.departure, from, Modifier.weight(1f))
                Text(
                    "→",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(horizontal = 8.dp)
                )
                LegEnd(flight.arrival, to, Modifier.weight(1f), alignEnd = true)
            }
        }
    }
}

@Composable
private fun LegEnd(code: String, airport: Airport?, modifier: Modifier, alignEnd: Boolean = false) {
    Column(
        modifier = modifier,
        horizontalAlignment = if (alignEnd) Alignment.End else Alignment.Start
    ) {
        Text(code, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text(
            airport?.city ?: "",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

@Composable
private fun StatCell(value: String, unit: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                value,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.titleLarge
            )
            if (unit.isNotEmpty()) {
                Text(
                    unit,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 2.dp, bottom = 3.dp)
                )
            }
        }
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp)
        )
    }
}
