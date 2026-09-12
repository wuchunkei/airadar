package com.airadar.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.systemPrefersMetric
import com.airadar.app.ui.components.MapRoute
import com.airadar.app.ui.components.MapTrack
import com.airadar.app.ui.components.TileMap
import com.airadar.app.ui.components.toMapRoutes
import com.airadar.app.ui.viewmodel.travelStats

@Composable
fun MyScreen(
    flights: List<Flight>,
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

    Box(modifier = modifier.fillMaxSize()) {

        // Full-bleed map; pinch to zoom, drag to pan.
        TileMap(
            routes = routes,
            tracks = tracks,
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

        Surface(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(12.dp),
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
