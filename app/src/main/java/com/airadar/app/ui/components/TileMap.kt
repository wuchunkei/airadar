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
import org.osmdroid.events.MapEventsReceiver
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.BoundingBox
import org.osmdroid.util.GeoPoint as OsmGeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.MapEventsOverlay
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.Polyline
import org.osmdroid.views.overlay.TilesOverlay
import org.osmdroid.views.overlay.milestones.MilestoneManager
import org.osmdroid.views.overlay.milestones.MilestoneMeterDistanceLister
import org.osmdroid.views.overlay.milestones.MilestonePathDisplayer

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
    interactive: Boolean = true,
    /** The leg drawn in the accent colour, matched by airport codes. */
    selected: Pair<Airport, Airport>? = null,
    /** A tap on a route or track, as its endpoints. */
    onLegClick: ((from: Airport, to: Airport) -> Unit)? = null,
    /** A tap on the map away from any leg. */
    onMapTap: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val dark = isSystemInDarkTheme()

    val routeColor = (if (dark) Color(0xFF4FD8C4) else Color(0xFF0B6FD4)).toArgb()
    val selectedColor = (if (dark) Color(0xFFFFD166) else Color(0xFFE8590C)).toArgb()
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

            // Overlays get taps last-added first, so the catch-all goes in at the
            // bottom and only hears taps no leg or airport claimed.
            if (onMapTap != null) {
                map.overlays.add(MapEventsOverlay(object : MapEventsReceiver {
                    override fun singleTapConfirmedHelper(p: OsmGeoPoint?): Boolean {
                        onMapTap()
                        return true
                    }

                    override fun longPressHelper(p: OsmGeoPoint?): Boolean = false
                }))
            }

            fun isSelected(from: Airport, to: Airport) =
                selected != null && selected.first.iata == from.iata && selected.second.iata == to.iata

            fun Polyline.leg(from: Airport, to: Airport, width: Float) {
                val color = if (isSelected(from, to)) selectedColor else routeColor
                outlinePaint.color = color
                outlinePaint.strokeWidth = width
                outlinePaint.isAntiAlias = true
                // osmdroid clears this list on detach, so it must be a mutable one.
                setMilestoneManagers(arrayListOf(midpointArrow(distance, color)))
                // No bubble: a tap is reported upward and the screen decides what to show.
                infoWindow = null
                setOnClickListener { _, _, _ ->
                    onLegClick?.invoke(from, to)
                    onLegClick != null
                }
            }

            // Selected leg last, so it paints over the others where they cross.
            routes.sortedBy { isSelected(it.from, it.to) }.forEach { route ->
                map.overlays.add(
                    Polyline(map).apply {
                        setPoints(
                            greatCirclePath(
                                GeoPoint(route.from.latitude, route.from.longitude),
                                GeoPoint(route.to.latitude, route.to.longitude)
                            ).map { OsmGeoPoint(it.lat, it.lon) }
                        )
                        leg(route.from, route.to, (3f + route.weight).coerceAtMost(9f))
                    }
                )
            }

            tracks.sortedBy { isSelected(it.from, it.to) }.forEach { track ->
                map.overlays.add(
                    Polyline(map).apply {
                        setPoints(track.points.map { OsmGeoPoint(it.lat, it.lon) })
                        leg(track.from, track.to, 4f)
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
                            infoWindow = null
                            setOnMarkerClickListener { _, _ -> true }
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
 * One arrowhead halfway along a line, pointing the way the flight goes.
 * [lengthMeters] is the line's own length, so the head lands on its middle at any zoom.
 */
private fun midpointArrow(lengthMeters: Double, color: Int): MilestoneManager {
    val head = Path().apply {
        moveTo(-9f, -8f)
        lineTo(9f, 0f)
        lineTo(-9f, 8f)
        close()
    }
    val paint = Paint().apply {
        this.color = color
        style = Paint.Style.FILL
        isAntiAlias = true
    }
    return MilestoneManager(
        MilestoneMeterDistanceLister(doubleArrayOf(lengthMeters / 2)),
        MilestonePathDisplayer(0.0, true, head, paint)
    )
}

private fun dotDrawable(color: Int) = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(color)
    setStroke(3, AndroidColor.WHITE)
    setSize(22, 22)
}
