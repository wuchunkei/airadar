package com.airadar.app.ui.components

import android.graphics.Color as AndroidColor
import android.graphics.Point
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.GradientDrawable
import android.view.MotionEvent
import java.io.File
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.airadar.app.BuildConfig
import com.airadar.app.data.Airport
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightDatabase
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.LivePosition
import com.airadar.app.data.greatCircleKm
import com.airadar.app.data.Region
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
import org.osmdroid.views.overlay.milestones.MilestoneManager
import org.osmdroid.views.overlay.milestones.MilestoneMeterDistanceLister
import org.osmdroid.views.overlay.milestones.MilestonePathDisplayer
import java.time.Instant
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.log2
import kotlin.math.tan

/**
 * One flight's leg. [rank] counts earlier legs in the same direction between
 * the same two airports: each repeat bows a little further out, so none
 * overlap and a tap can always tell exactly which one it landed on. [isReturn]
 * marks the direction opposite to the pair's first flight; it bows to the
 * other side of the line between the two, mirroring the outbound arcs.
 */
data class MapRoute(
    val from: Airport,
    val to: Airport,
    val rank: Int = 0,
    val isReturn: Boolean = false,
    /** Set while the flight is in the air with no real track yet: the share
     * of the way flown by the clock. The arc is then dashed, the flown part
     * solid, a plane at the point -- the real ADS-B point when [TileMap]'s
     * own livePlane has one (the arc is cut where it comes nearest), the
     * timetable's estimate otherwise. */
    val progress: Double? = null
)

/** A leg drawn along the positions it actually reported, instead of a bowed arc. */
data class MapTrack(
    val from: Airport,
    val to: Airport,
    val points: List<TrackPoint>,
    /** Still flying: the track is drawn solid with a plane at its end, and
     * the remaining way to the destination is drawn dashed past it. */
    val live: Boolean = false,
    /** Expected landing, delay included, and the minute this is drawn for: with
     * both, a live track whose last real fix has gone stale (out of receiver
     * range over the sea, say) gets the plane moved on to where it should be by now. */
    val eta: java.time.Instant? = null,
    val now: java.time.Instant? = null,
) {
    /** Where the plane should be by [now], along the way from its last real fix
     * to the destination, in proportion to the time from that fix to [eta].
     * Null while the last fix is still fresh (under ten minutes old). */
    val estimatedPosition: OsmGeoPoint?
        get() {
            if (!live) return null
            val now = now ?: return null
            val eta = eta ?: return null
            val last = points.lastOrNull() ?: return null
            val seen = last.time ?: return null
            val sinceFix = java.time.Duration.between(seen, now).seconds
            val fixToEta = java.time.Duration.between(seen, eta).seconds
            if (sinceFix <= 600 || fixToEta <= 0) return null
            val fraction = minOf(0.97, sinceFix.toDouble() / fixToEta)
            val path = arcPath(last.lat, last.lon, to.latitude, to.longitude)
            return path[((path.size - 1) * fraction).toInt()]
        }
}

/** A leg per flight, oldest first, ranked among its repeats. */
fun List<Flight>.toMapRoutes(): List<MapRoute> {
    val seen = mutableMapOf<String, Int>()
    val firstFrom = mutableMapOf<String, String>()
    val out = mutableListOf<MapRoute>()
    for (flight in sortedBy { it.departureInstant ?: Instant.MIN }) {
        val from = flight.departureAirport ?: continue
        val to = flight.arrivalAirport ?: continue
        val pair = listOf(from.iata, to.iata).sorted().joinToString("-")
        val way = "${from.iata}>${to.iata}"
        val rank = seen.getOrDefault(way, 0)
        seen[way] = rank + 1
        if (firstFrom[pair] == null) firstFrom[pair] = from.iata
        out += MapRoute(
            from, to, rank, isReturn = firstFrom[pair] != from.iata,
            progress = if (flight.phase == FlightPhase.IN_PROGRESS) flight.fractionFlown else null
        )
    }
    return out
}

// Spherical Web Mercator, y increasing north (the standard math convention) --
// the sign flips against MapKit's own MKMapPoint, which runs y increasing
// south (screen-like); arcPath below is derived fresh for this convention,
// not a blind port of the iOS formula.
private const val EARTH_RADIUS = 6378137.0

private fun mercatorX(lon: Double): Double = Math.toRadians(lon) * EARTH_RADIUS

private fun mercatorY(lat: Double): Double {
    val rad = Math.toRadians(lat.coerceIn(-85.05, 85.05))
    return EARTH_RADIUS * ln(tan(PI / 4 + rad / 2))
}

private fun inverseMercator(x: Double, y: Double): OsmGeoPoint {
    val lon = Math.toDegrees(x / EARTH_RADIUS)
    val lat = Math.toDegrees(2 * atan(exp(y / EARTH_RADIUS)) - PI / 2)
    return OsmGeoPoint(lat, lon)
}

/**
 * The bowed line between two airports. The rule: every flight keeps to the
 * RIGHT of its direction of travel — northbound bows east, southbound west,
 * eastbound south, westbound north — so the way out and the way back sit on
 * opposite sides of the line between the two airports, and every repeat in
 * one direction steps a fixed amount further out on its own side.
 */
fun arcPath(from: Airport, to: Airport, rank: Int = 0): List<OsmGeoPoint> =
    arcPath(from.latitude, from.longitude, to.latitude, to.longitude, rank)

/** The coordinate-only core [arcPath] delegates to -- also used to draw the
 * remaining way from a live in-flight position (not an airport) onward to
 * the destination. */
fun arcPath(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double, rank: Int = 0): List<OsmGeoPoint> {
    val p0x = mercatorX(fromLon); val p0y = mercatorY(fromLat)
    val p2x = mercatorX(toLon); val p2y = mercatorY(toLat)
    val dx = p2x - p0x; val dy = p2y - p0y
    val length = hypot(dx, dy)
    if (length == 0.0) return listOf(OsmGeoPoint(fromLat, fromLon), OsmGeoPoint(toLat, toLon))
    val bulge = minOf(0.14 + 0.09 * rank, 0.7)
    // "Right of travel" in a y-north-positive system is the (dy, -dx)
    // rotation of the direction vector (verified against due-east and
    // due-north test cases against the rule stated above).
    val cx = (p0x + p2x) / 2 + dy * bulge
    val cy = (p0y + p2y) / 2 - dx * bulge
    val steps = 48
    return (0..steps).map { i ->
        val t = i.toDouble() / steps; val u = 1 - t
        val x = u * u * p0x + 2 * u * t * cx + t * t * p2x
        val y = u * u * p0y + 2 * u * t * cy + t * t * p2y
        inverseMercator(x, y)
    }
}

/** Initial great-circle bearing from [a] to [b], degrees clockwise from north. */
private fun bearing(a: OsmGeoPoint, b: OsmGeoPoint): Double {
    val rad = PI / 180
    val dLon = (b.longitude - a.longitude) * rad
    val y = kotlin.math.sin(dLon) * kotlin.math.cos(b.latitude * rad)
    val x = kotlin.math.cos(a.latitude * rad) * kotlin.math.sin(b.latitude * rad) -
        kotlin.math.sin(a.latitude * rad) * kotlin.math.cos(b.latitude * rad) * kotlin.math.cos(dLon)
    return ((kotlin.math.atan2(y, x) / rad) + 360) % 360
}

/** Index of the arc point nearest a live fix, in planar (Mercator) distance --
 * where the flown/still-to-go split actually falls once a real ADS-B point
 * is in hand, rather than the schedule's own estimate. */
private fun nearestIndex(coords: List<OsmGeoPoint>, lat: Double, lon: Double): Int {
    val px = mercatorX(lon); val py = mercatorY(lat)
    var bestIndex = 0
    var bestDist = Double.MAX_VALUE
    coords.forEachIndexed { i, p ->
        val dx = mercatorX(p.longitude) - px
        val dy = mercatorY(p.latitude) - py
        val d = dx * dx + dy * dy
        if (d < bestDist) { bestDist = d; bestIndex = i }
    }
    return bestIndex
}

/** OpenStreetMap tile map with bowed arc routes and flown tracks drawn on top. */
@Composable
fun TileMap(
    routes: List<MapRoute>,
    modifier: Modifier = Modifier,
    tracks: List<MapTrack> = emptyList(),
    /** False for a thumbnail: touches fall through so the sheet around it still scrolls. */
    interactive: Boolean = true,
    /** Colour by compass direction (north blue, south green) instead of
     * outbound/return — for the My overview, where one line per leg reads
     * better by which way it points than by which trip it belonged to. */
    directionColored: Boolean = false,
    /** The one leg to highlight — (from, to, rank), naming the exact repeat
     * of that pair a line tap picked out — or null for none. */
    selected: Triple<Airport, Airport, Int>? = null,
    /** A tap on one line: which leg, exactly (never more than one, even
     * where several repeats of the same pair run together). */
    onLegClick: ((Airport, Airport, Int) -> Unit)? = null,
    /** A tap on an airport's dot: every (from, to) pair actually touching
     * it — an airport can sit on several different routes at once, which
     * is a different case from the same-pair-repeated one [selected] and
     * [onLegClick] exist for, so this stays a plain aggregate list. */
    onAirportClick: ((List<Pair<Airport, Airport>>) -> Unit)? = null,
    /** A tap on the map away from any leg. */
    onMapTap: (() -> Unit)? = null,
    /** Where to look while there are no legs at all — roughly where the traveller is. */
    emptyFocus: Region? = null,
    /** Where the aircraft actually is (ADS-B); with it, a route's own plane
     * (see [MapRoute.progress]) leaves the schedule's estimate for the real
     * point. Never drawn on its own -- only ever refines a route or track
     * that's already asking for a plane. */
    livePlane: LivePosition? = null,
    /** The dot — off by default. On, [followUser] decides whether the
     * camera actually follows it too. */
    showsUserLocation: Boolean = false,
    /** The latest fix to show the dot at; null hides it even if
     * [showsUserLocation] is true (no fix yet, or permission not granted). */
    userLocation: android.location.Location? = null,
    /** True re-centres the camera on [userLocation] each time it changes —
     * a plain pan (MapView.controller.animateTo), never a zoom change, so
     * whatever zoom is already showing the route network survives. */
    followUser: Boolean = false,
    /** A manual drag or pinch while [followUser] is true: the caller
     * should let go of it, the same way it would with any other "follow
     * me" map button. Never fired for the pan this composable makes
     * itself when centring on a new fix. */
    onUserPanned: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // The tiles are OSM's standard style whatever the app theme, so the line
    // colours are picked once, against that light ground.
    val routeColor = Color(0xFF0B6FD4).toArgb()
    val returnColor = Color(0xFF009688).toArgb()
    val directionNorthColor = Color(0xFF0A70D4).toArgb()
    val directionSouthColor = Color(0xFF00994D).toArgb()
    val selectedColor = Color(0xFFE8590C).toArgb()
    val nodeColor = Color(0xFF0A4F96).toArgb()
    val liveColor = Color(0xFF2ECC71).toArgb()
    val dashedColor = AndroidColor.argb(153, 128, 128, 128)

    val framedFor = remember(interactive) { intArrayOf(0) }
    // Set only while this composable's own animateTo (in the location
    // LaunchedEffect below) is moving the camera, so that pan isn't
    // mistaken for the traveller taking hold of the map themselves.
    val programmaticPan = remember(interactive) { booleanArrayOf(false) }
    // Every overlay the route/track-drawing pass below owns, so its own
    // redraw can clear just those and never touch the location marker,
    // which lives on the map independently of route changes.
    val ownedOverlays = remember(interactive) { mutableListOf<org.osmdroid.views.overlay.Overlay>() }
    // The map view's own MapListener is set up once (below, inside the
    // remember block that builds it) and would otherwise close over
    // whichever onUserPanned instance existed at that first composition —
    // this indirection cell is updated on every recomposition instead, so
    // the listener always calls the current one.
    val onUserPannedRef = remember(interactive) { arrayOfNulls<() -> Unit>(1) }
    onUserPannedRef[0] = onUserPanned

    val mapView = remember(interactive) {
        Configuration.getInstance().apply {
            // OSM's tile policy requires an identifying user agent.
            userAgentValue = context.packageName
            // Cache inside the app's own storage: always writable, cleared with the app.
            osmdroidBasePath = File(context.cacheDir, "osmdroid")
            osmdroidTileCache = File(context.cacheDir, "osmdroid/tiles")
            // Debug builds log every tile request, so a blank map can be diagnosed from logcat.
            isDebugTileProviders = BuildConfig.DEBUG
        }
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
            // Nothing past the poles: the map stops at the top and bottom of the world.
            val tiles = MapView.getTileSystem()
            setScrollableAreaLimitLatitude(tiles.maxLatitude, tiles.minLatitude, 0)
            setMaxZoomLevel(18.0)
            // And no grey bands: the world may never be shorter than the screen.
            addOnFirstLayoutListener { v, _, _, _, _ ->
                val worldFits = ceil(log2(v.height / 256.0)).coerceAtLeast(2.0)
                setMinZoomLevel(worldFits)
                if (zoomLevelDouble < worldFits) controller.setZoom(worldFits)
            }
            // A manual drag or pinch while the camera is following the
            // traveller's own position: let go, the same way any other
            // "follow me" map button would -- but only for a scroll this
            // composable didn't itself just start via animateTo below.
            addMapListener(object : org.osmdroid.events.MapListener {
                override fun onScroll(event: org.osmdroid.events.ScrollEvent?): Boolean {
                    if (!programmaticPan[0]) onUserPannedRef[0]?.invoke()
                    return false
                }
                override fun onZoom(event: org.osmdroid.events.ZoomEvent?): Boolean = false
            })
        }
    }

    // The traveller's own position: outside the route-redraw pass below, so
    // its two overlays (dot + burst ring) are never touched by a route update.
    val locationMarker = remember(interactive) { LocationMarker(mapView) }

    DisposableEffect(lifecycleOwner, mapView) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> mapView.onResume()
                Lifecycle.Event.ON_PAUSE -> mapView.onPause()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            locationMarker.hide()
        }
    }

    LaunchedEffect(showsUserLocation, userLocation?.latitude, userLocation?.longitude, followUser) {
        val fix = userLocation
        if (showsUserLocation && fix != null) {
            val point = OsmGeoPoint(fix.latitude, fix.longitude)
            locationMarker.show(point)
            if (followUser) {
                // Flagged so the MapListener above doesn't mistake this
                // self-initiated pan for the traveller taking hold of the map.
                programmaticPan[0] = true
                mapView.controller.animateTo(point)
                kotlinx.coroutines.delay(400)
                programmaticPan[0] = false
            }
        } else {
            locationMarker.hide()
        }
    }

    AndroidView(
        factory = { mapView },
        modifier = modifier,
        // onRelease runs only after the view has left the hierarchy, so tearing the
        // map down here cannot race a final draw the way onDispose can.
        onRelease = { it.onDetach() },
        update = { map ->
            // Clears only what the previous run of this block itself added --
            // never the location marker's overlays, which live outside it.
            ownedOverlays.forEach { map.overlays.remove(it) }
            ownedOverlays.clear()
            fun addOwned(overlay: org.osmdroid.views.overlay.Overlay) {
                map.overlays.add(overlay)
                ownedOverlays.add(overlay)
            }

            data class Leg(val line: Polyline, val from: Airport, val to: Airport, val rank: Int)
            val legs = mutableListOf<Leg>()
            val density = map.resources.displayMetrics.density

            fun isSelected(from: Airport, to: Airport, rank: Int) =
                selected != null && selected.first.iata == from.iata && selected.second.iata == to.iata && selected.third == rank

            // Taps are resolved here rather than per line: osmdroid's own hit test is
            // only as wide as the stroke and hands the tap to whichever line is on top,
            // which makes a bundle of legs out of one hub impossible to pick apart.
            // Every leg's distance to the finger is measured in pixels and exactly one
            // — the nearest, if it is within reach — is reported, rank included, so a
            // tap on one repeat of a pair never lights up every repeat of it.
            addOwned(MapEventsOverlay(object : MapEventsReceiver {
                override fun singleTapConfirmedHelper(p: OsmGeoPoint?): Boolean {
                    if (p == null) return false
                    val tap = map.projection.toPixels(p, null)
                    val nearest = legs
                        .map { it to it.line.pixelDistanceTo(tap, map) }
                        .minByOrNull { it.second }
                        ?.takeIf { it.second <= 28f * density }
                        ?.first
                    if (nearest != null) onLegClick?.invoke(nearest.from, nearest.to, nearest.rank)
                    else onMapTap?.invoke()
                    return true
                }

                override fun longPressHelper(p: OsmGeoPoint?): Boolean = false
            }))

            fun directionColor(from: Airport, to: Airport) =
                if (to.latitude >= from.latitude) directionNorthColor else directionSouthColor

            // Selected leg last, so it paints over the others where they cross.
            routes.sortedBy { isSelected(it.from, it.to, it.rank) }.forEach { route ->
                val progress = route.progress
                if (progress != null) {
                    val coords = arcPath(route.from, route.to, route.rank)
                    // Whole way dashed; the part flown solid; the plane at
                    // the point reached -- the real ADS-B point when
                    // livePlane has one (the arc is cut where it comes
                    // nearest), the timetable's own estimate otherwise.
                    val whole = Polyline(map).apply {
                        setPoints(coords)
                        outlinePaint.color = dashedColor
                        outlinePaint.strokeWidth = 2.5f
                        outlinePaint.isAntiAlias = true
                        outlinePaint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(14f, 10f), 0f)
                        infoWindow = null
                        setOnClickListener { _, _, _ -> false }
                    }
                    addOwned(whole)
                    legs += Leg(whole, route.from, route.to, route.rank)

                    var cut = (((coords.size - 1) * progress).toInt() + 1).coerceIn(2, coords.size)
                    var planeAt = coords[cut - 1]
                    var heading = bearing(coords[maxOf(0, cut - 2)], coords[cut - 1])
                    // A fix over ten minutes old is where it was, not where it is:
                    // past that, the timetable's estimate is the better guess.
                    if (livePlane != null && java.time.Duration.between(livePlane.seenAt, java.time.Instant.now()).seconds < 600) {
                        cut = (nearestIndex(coords, livePlane.lat, livePlane.lon) + 1).coerceIn(2, coords.size)
                        planeAt = OsmGeoPoint(livePlane.lat, livePlane.lon)
                        heading = livePlane.heading
                    }
                    addOwned(
                        Polyline(map).apply {
                            setPoints(coords.take(cut))
                            outlinePaint.color = liveColor
                            outlinePaint.strokeWidth = 4f
                            outlinePaint.isAntiAlias = true
                            infoWindow = null
                            setOnClickListener { _, _, _ -> false }
                        }
                    )
                    addOwned(
                        Marker(map).apply {
                            position = planeAt
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            icon = planeDrawable(liveColor, density)
                            rotation = heading.toFloat()
                            infoWindow = null
                        }
                    )
                    return@forEach
                }
                addOwned(
                    Polyline(map).apply {
                        setPoints(arcPath(route.from, route.to, route.rank))
                        val base = if (directionColored) directionColor(route.from, route.to)
                        else if (route.isReturn) returnColor else routeColor
                        val color = if (isSelected(route.from, route.to, route.rank)) selectedColor else base
                        outlinePaint.color = color
                        outlinePaint.strokeWidth = 4f
                        outlinePaint.isAntiAlias = true
                        // osmdroid clears this list on detach, so it must be a mutable one.
                        setMilestoneManagers(arrayListOf(midpointArrow(distance, color)))
                        // No bubble, and no claim on the tap: the events overlay above decides.
                        infoWindow = null
                        setOnClickListener { _, _, _ -> false }
                        legs += Leg(this, route.from, route.to, route.rank)
                    }
                )
            }

            tracks.forEach { track ->
                val isSel = isSelected(track.from, track.to, 0)
                val coords = track.points.map { OsmGeoPoint(it.lat, it.lon) }
                val color = if (isSel) selectedColor else if (track.live) liveColor else routeColor
                addOwned(
                    Polyline(map).apply {
                        setPoints(coords)
                        outlinePaint.color = color
                        outlinePaint.strokeWidth = 4f
                        outlinePaint.isAntiAlias = true
                        // A still-flying track ends mid-air; the midpoint
                        // arrow only makes sense once the whole leg is known.
                        if (!track.live) setMilestoneManagers(arrayListOf(midpointArrow(distance, color)))
                        infoWindow = null
                        setOnClickListener { _, _, _ -> false }
                        legs += Leg(this, track.from, track.to, 0)
                    }
                )
                if (track.live && coords.size >= 2) {
                    var last = coords.last()
                    var heading = bearing(coords[coords.size - 2], last)
                    track.estimatedPosition?.let { estimate ->
                        // Out of receiver range: dashed green from the last real fix
                        // to where it should be by now, so the estimate reads as one.
                        val gap = arcPath(last.latitude, last.longitude, estimate.latitude, estimate.longitude)
                        addOwned(
                            Polyline(map).apply {
                                setPoints(gap)
                                outlinePaint.color = liveColor
                                outlinePaint.strokeWidth = 4f
                                outlinePaint.isAntiAlias = true
                                outlinePaint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(14f, 10f), 0f)
                                infoWindow = null
                                setOnClickListener { _, _, _ -> false }
                            }
                        )
                        if (gap.size >= 2) heading = bearing(gap[gap.size - 2], estimate)
                        last = estimate
                    }
                    addOwned(
                        Marker(map).apply {
                            position = last
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            icon = planeDrawable(liveColor, density)
                            rotation = heading.toFloat()
                            infoWindow = null
                        }
                    )
                    // The way still to go, dashed, so the map frames the
                    // whole flight and not just the bit already flown.
                    val rest = arcPath(last.latitude, last.longitude, track.to.latitude, track.to.longitude)
                    addOwned(
                        Polyline(map).apply {
                            setPoints(rest)
                            outlinePaint.color = dashedColor
                            outlinePaint.strokeWidth = 2.5f
                            outlinePaint.isAntiAlias = true
                            outlinePaint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(14f, 10f), 0f)
                            infoWindow = null
                            setOnClickListener { _, _, _ -> false }
                        }
                    )
                } else if (coords.size >= 2 &&
                    greatCircleKm(coords.last().latitude, coords.last().longitude, track.to.latitude, track.to.longitude) > 50
                ) {
                    // A finished flight whose recorded track stops short (no receivers
                    // along the rest of the way): the rest dashed to where it landed,
                    // so it reads as unrecorded, not as a plane that vanished midway.
                    addOwned(
                        Polyline(map).apply {
                            setPoints(arcPath(coords.last().latitude, coords.last().longitude, track.to.latitude, track.to.longitude))
                            outlinePaint.color = color
                            outlinePaint.strokeWidth = 2.5f
                            outlinePaint.isAntiAlias = true
                            outlinePaint.pathEffect = android.graphics.DashPathEffect(floatArrayOf(14f, 10f), 0f)
                            infoWindow = null
                            setOnClickListener { _, _, _ -> false }
                        }
                    )
                }
            }

            (routes.flatMap { listOf(it.from, it.to) } + tracks.flatMap { listOf(it.from, it.to) })
                .distinctBy { it.iata }
                .forEach { airport ->
                    addOwned(
                        Marker(map).apply {
                            position = OsmGeoPoint(airport.latitude, airport.longitude)
                            setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                            icon = dotDrawable(nodeColor)
                            infoWindow = null
                            setOnMarkerClickListener { _, _ ->
                                val touching = legs
                                    .filter { it.from.iata == airport.iata || it.to.iata == airport.iata }
                                    .map { it.from to it.to }
                                    .distinct()
                                if (touching.isNotEmpty()) onAirportClick?.invoke(touching)
                                true
                            }
                        }
                    )
                }

            map.invalidate()

            // Frame the network once per route set, so a later redraw does not
            // yank the map out from under a pinch the traveller just made.
            val key = routes.hashCode() * 31 + tracks.hashCode()
            if (routes.isEmpty() && tracks.isEmpty()) {
                // Nothing to frame: settle on the traveller's own region rather than
                // a world-wide strip of repeated continents.
                val focusKey = emptyFocus.hashCode()
                if (emptyFocus != null && framedFor[0] != focusKey) {
                    framedFor[0] = focusKey
                    val look = { m: MapView ->
                        m.controller.setZoom(emptyFocus.zoom)
                        m.controller.setCenter(OsmGeoPoint(emptyFocus.latitude, emptyFocus.longitude))
                    }
                    if (map.width > 0) look(map) else map.addOnFirstLayoutListener { _, _, _, _, _ -> look(map) }
                }
            } else if (framedFor[0] != key) {
                framedFor[0] = key
                val corners = routes.flatMap { arcPath(it.from, it.to, it.rank) } +
                    tracks.flatMap { track ->
                        // A still-flying track's own points end mid-air; the destination is
                        // included too, so the frame doesn't crop the way still to go.
                        track.points.map { OsmGeoPoint(it.lat, it.lon) } +
                            if (track.live) listOf(OsmGeoPoint(track.to.latitude, track.to.longitude)) else emptyList()
                    }
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

/** Shortest screen distance from [tap] to any segment of this line, in pixels. */
private fun Polyline.pixelDistanceTo(tap: Point, map: MapView): Double {
    val projection = map.projection
    val scratch = Point()
    var best = Double.MAX_VALUE
    var prevX = 0.0
    var prevY = 0.0
    actualPoints.forEachIndexed { i, geo ->
        projection.toPixels(geo, scratch)
        val x = scratch.x.toDouble()
        val y = scratch.y.toDouble()
        if (i > 0) best = minOf(best, distanceToSegment(tap.x.toDouble(), tap.y.toDouble(), prevX, prevY, x, y))
        prevX = x
        prevY = y
    }
    return best
}

private fun distanceToSegment(px: Double, py: Double, ax: Double, ay: Double, bx: Double, by: Double): Double {
    val dx = bx - ax
    val dy = by - ay
    val lengthSq = dx * dx + dy * dy
    val t = if (lengthSq == 0.0) 0.0 else ((px - ax) * dx + (py - ay) * dy / lengthSq).coerceIn(0.0, 1.0)
    val cx = ax + t * dx
    val cy = ay + t * dy
    return hypot(px - cx, py - cy)
}

private fun dotDrawable(color: Int) = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(color)
    setStroke(3, AndroidColor.WHITE)
    setSize(22, 22)
}

/** A plane glyph pointing north at rotation 0 -- [Marker.rotation] turns it
 * to the actual heading from there, the same way iOS turns its own "airplane"
 * SF Symbol to match. */
private fun planeDrawable(color: Int, density: Float): android.graphics.drawable.BitmapDrawable {
    val size = (26 * density).toInt().coerceAtLeast(18)
    val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bitmap)
    val paint = Paint().apply { this.color = color; style = Paint.Style.FILL; isAntiAlias = true }
    val c = size / 2f
    val path = Path().apply {
        moveTo(c, c - size * 0.44f)
        lineTo(c + size * 0.32f, c + size * 0.34f)
        lineTo(c, c + size * 0.14f)
        lineTo(c - size * 0.32f, c + size * 0.34f)
        close()
    }
    canvas.drawPath(path, paint)
    return android.graphics.drawable.BitmapDrawable(android.content.res.Resources.getSystem(), bitmap)
}

private val userLocationColor = AndroidColor.rgb(46, 204, 113)

/** A ring of [radiusPx], stroked at [alpha] -- transparent inside, so the
 * solid dot underneath still shows through while it expands and fades. */
private fun ringDrawable(radiusPx: Int, alpha: Int) = GradientDrawable().apply {
    shape = GradientDrawable.OVAL
    setColor(AndroidColor.TRANSPARENT)
    setStroke((radiusPx / 8).coerceAtLeast(2), AndroidColor.argb(alpha, 46, 204, 113))
    setSize(radiusPx * 2, radiusPx * 2)
}

/**
 * The traveller's own position on the map: a small solid green dot that
 * stays put, plus a ring that expands and fades once every ten seconds --
 * a burst, like the equivalent view on iOS, not a continuous pulse, so it
 * doesn't compete for attention with the route lines. Both overlays live
 * outside [TileMap]'s route-redraw pass, added directly to the [map] here
 * and never touched by that pass's own overlay bookkeeping.
 */
private class LocationMarker(private val map: MapView) {
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var attached = false
    private var burstRunnable: Runnable? = null
    private var stepRunnable: Runnable? = null

    private val dot = Marker(map).apply {
        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
        icon = dotDrawable(userLocationColor)
        infoWindow = null
    }
    private val ring = Marker(map).apply {
        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
        infoWindow = null
    }

    fun show(point: OsmGeoPoint) {
        dot.position = point
        ring.position = point
        if (!attached) {
            map.overlays.add(ring)
            map.overlays.add(dot)
            attached = true
            scheduleBurst()
        }
        map.invalidate()
    }

    fun hide() {
        if (attached) {
            map.overlays.remove(dot)
            map.overlays.remove(ring)
            attached = false
        }
        burstRunnable?.let(handler::removeCallbacks)
        stepRunnable?.let(handler::removeCallbacks)
        burstRunnable = null
        stepRunnable = null
    }

    private fun scheduleBurst() {
        val runnable = object : Runnable {
            override fun run() {
                if (!attached) return
                animateBurst()
                handler.postDelayed(this, 10_000)
            }
        }
        burstRunnable = runnable
        handler.post(runnable)
    }

    private fun animateBurst() {
        val density = map.resources.displayMetrics.density
        val steps = 12
        var i = 0
        val step = object : Runnable {
            override fun run() {
                if (!attached) return
                val t = i / steps.toFloat()
                val radiusPx = ((10 + 26 * t) * density).toInt().coerceAtLeast(1)
                val alpha = (255 * (1f - t)).toInt().coerceIn(0, 255)
                ring.icon = ringDrawable(radiusPx, alpha)
                map.invalidate()
                i++
                if (i <= steps) handler.postDelayed(this, 45L) else ring.icon = null
            }
        }
        stepRunnable = step
        handler.post(step)
    }
}
