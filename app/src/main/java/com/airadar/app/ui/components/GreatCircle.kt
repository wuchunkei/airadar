package com.airadar.app.ui.components

import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

data class GeoPoint(val lat: Double, val lon: Double)

/**
 * Samples the great-circle path between two coordinates. A flight follows this arc,
 * not a straight line on a flat map, so the drawn route matches how the aircraft
 * actually crosses the globe.
 */
fun greatCirclePath(from: GeoPoint, to: GeoPoint, segments: Int = 64): List<GeoPoint> {
    val lat1 = Math.toRadians(from.lat)
    val lon1 = Math.toRadians(from.lon)
    val lat2 = Math.toRadians(to.lat)
    val lon2 = Math.toRadians(to.lon)

    val d = 2 * asin(
        sqrt(
            sin((lat1 - lat2) / 2).let { it * it } +
                cos(lat1) * cos(lat2) * sin((lon1 - lon2) / 2).let { it * it }
        )
    )
    if (d == 0.0 || d.isNaN()) return listOf(from, to)

    return (0..segments).map { i ->
        val f = i.toDouble() / segments
        val a = sin((1 - f) * d) / sin(d)
        val b = sin(f * d) / sin(d)
        val x = a * cos(lat1) * cos(lon1) + b * cos(lat2) * cos(lon2)
        val y = a * cos(lat1) * sin(lon1) + b * cos(lat2) * sin(lon2)
        val z = a * sin(lat1) + b * sin(lat2)
        GeoPoint(
            lat = Math.toDegrees(atan2(z, sqrt(x * x + y * y))),
            lon = Math.toDegrees(atan2(y, x))
        )
    }
}
