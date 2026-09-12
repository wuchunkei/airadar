package com.airadar.app.ui.components

import android.graphics.Color as AndroidColor
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.airadar.app.data.Airport
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightDatabase
import com.airadar.app.data.TrackPoint
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint as OsmGeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.TilesOverlay
import org.osmdroid.views.overlay.milestones.MilestoneManager
import org.osmdroid.views.overlay.milestones.MilestonePathDisplayer
import org.osmdroid.views.overlay.milestones.MilestonePixelDistanceLister

data class MapRoute(
    val from: Airport,
    val to: Airport,
    val weight: Int = 1
)

/** A leg drawn along the positions it actually reported, instead of a great circle. */
data class MapTrack(
    val from: Airport,
    val to: Airport,
    val points: List<TrackPoint>
)

/** Collapses a trip list into unique routes, weighted by how often each was flown. */
fun List<Flight>.toMapRoutes(): List<MapRoute> =
    mapNotNull { flight ->
        val from = FlightDatabase.airport(flight.departure) ?: return@mapNotNull null
        val to = FlightDatabase.airport(flight.arrival) ?: return@mapNotNull null
        Pair(from, to)
    }
        .groupingBy { it }
        .eachCount()
        .map { (pair, count) -> MapRoute(pair.first, pair.second, count) }

/** OpenStreetMap tile map with great-circle routes and flown tracks drawn on top. */
@Composable
fun TileMap(
    routes: List<MapRoute>,
    modifier: Modifier = Modifier,
    tracks: List<MapTrack> = emptyList(),
    /** False for a thumbnail: touches fall through so the sheet around it still scrolls. */
    interactive: Boolean = true
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val dark = isSystemInDarkTheme()

    val routeColor = (if (dark) Color(0xFF4FD8C4) else Color(0xFF0B6FD4)).toArgb()
    val nodeColor = (if (dark) Color(0xFF9DF5E6) else Color(0xFF0A4F96)).toArgb()

    val framedFor = remember(interactive) { intArrayOf(0) }

    val mapView = remember(interactive) {
        // OSM's tile policy requires an identifying user agent.
        Configuration.getInstance().userAgentValue = context.packageName
        val view = if (interactive) MapView(context) else object : MapView(context) {
            // Declining every event hands it to the Compose parent untouched.
            override fun dispatchTouchEvent(ev: MotionEvent?): Boolean = false
        }
        view.apply {
            setTileSource(TileSourceFactory.MAPNIK)
            setMultiTouchControls(interactive)
            zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
            isHorizontalMapRepetitionEnabled = true
            isVerticalMapRepetitionEnabled = false
            setMinZoomLevel(2.0)
            setMaxZoomLevel(18.0)
        }
    }

    DisposableEffect(lifecycleOwner, mapView) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    AndroidView(
        factory = { mapView },
        modifier = modifier,
        // onRelease runs only after the view has left the hierarchy, so tearing the
        // map down here cannot race a final draw the way onDispose can.
        onRelease = { it.onDetach() },
        update = { map ->
            val filter = if (dark) TilesOverlay.INVERT_COLORS else null
            map.overlayManager.tilesOverlay.setColorFilter(filter)

            map.overlays.clear()

            routes.forEach { route ->
                map.overlays.add(
                    Polyline(map).apply {
                        setPoints(
                            greatCirclePath(
                                GeoPoint(route.from.latitude, route.from.longitude),
                                GeoPoint(route.to.latitude, route.to.longitude)
                            ).map { OsmGeoPoint(it.lat, it.lon) }
                        )
                        outlinePaint.color = routeColor
                        outlinePaint.strokeWidth = (3f + route.weight).coerceAtMost(9f)
                        outlinePaint.isAntiAlias = true
                        setMilestoneManagers(listOf(directionArrows(routeColor)))
                    }
                )
            }

            tracks.forEach { track ->
                map.overlays.add(
                    Polyline(map).apply {
                        setPoints(track.points.map { OsmGeoPoint(it.lat, it.lon) })
                        outlinePaint.color = routeColor
                        outlinePaint.strokeWidth = 4f
                        outlinePaint.isAntiAlias = true
                        setMilestoneManagers(listOf(directionArrows(routeColor)))
                    }
                )
            }

            (routes.flatMap { listOf(it.from, it.to) } + tracks.flatMap { listOf(it.from, it.to) })
                .distinctBy { it.iata }
                .forEach { airport ->
                    map.overlays.add(
                        Marker(map).apply {
                            position = OsmGeoPoint(airport.latitude, airport.longitude)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            icon = dotDrawable(nodeColor)
                            title = "${airport.iata} · ${airport.city}"
                        }
                    )
                }

            map.invalidate()

            // Frame the network once per route set, so a later redraw does not
            // yank the map out from under a pinch the traveller just made.
            val key = routes.hashCode() * 31 + tracks.hashCode()
            if ((routes.isNotEmpty() || tracks.isNotEmpty()) && framedFor[0] != key) {
                framedFor[0] = key
                val corners = routes.flatMap {
                    listOf(
                        OsmGeoPoint(it.from.latitude, it.from.longitude),
                        OsmGeoPoint(it.to.latitude, it.to.longitude)
                    )
                } + tracks.flatMap { track -> track.points.map { OsmGeoPoint(it.lat, it.lon) } }
                val box = BoundingBox.fromGeoPointsSafe(corners)
                val frame = { m: MapView -> m.zoomToBoundingBox(box, false, minOf(m.width, m.height) / 7) }
                if (map.width > 0) frame(map)
                else map.addOnFirstLayoutListener { _, _, _, _, _ -> frame(map) }
            }
        }
    )
}

/**
 * Arrowheads stamped along a line every ~110 px, pointing the way the flight goes.
 * Pixel spacing keeps the density the same whether zoomed to a city or the globe.
 */
private fun directionArrows(color: Int): MilestoneManager {
    val head = Path().apply {
        moveTo(-7f, -6f)
        lineTo(7f, 0f)
        lineTo(-7f, 6f)
        close()
    }
    val paint = Paint().apply {
        this.color = color
        style = Paint.Style.FILL
        isAntiAlias = true
    }
    return MilestoneManager(
        MilestonePixelDistanceLister(60.0, 110.0),
        MilestonePathDisplayer(0.0, true, head, paint)
    )
}

private fun dotDrawable(color: Int) = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(color)
    setStroke(3, AndroidColor.WHITE)
    setSize(22, 22)
}
