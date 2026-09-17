package com.airadar.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.airadar.app.data.MilestoneTier
import com.airadar.app.data.TierStanding
import com.airadar.app.data.mixed
import com.airadar.app.data.systemPrefersMetric

/** The medallion -- real per-tier artwork when its drawable is in
 * `res/drawable-nodpi/tier_<key>_logo.png`, a placeholder gradient if not
 * (a tier added here before its art arrives, say). */
@Composable
fun TierBadge(tier: MilestoneTier, size: androidx.compose.ui.unit.Dp = 28.dp) {
    // A distinct name from here down: inside Canvas's DrawScope, a bare
    // `size` resolves to its own (pixel) Size, not this Dp parameter.
    val diameter = size
    val context = LocalContext.current
    val resId = remember(tier) {
        context.resources.getIdentifier("tier_${tier.artKey}_logo", "drawable", context.packageName)
    }
    if (resId != 0) {
        AsyncImage(
            model = android.net.Uri.parse("android.resource://${context.packageName}/$resId"),
            contentDescription = tier.displayName,
            modifier = Modifier.size(size)
        )
    } else {
        Column(
            modifier = Modifier.size(size),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Surface(
                modifier = Modifier.size(diameter),
                shape = CircleShape,
                color = Color.Transparent
            ) {
                Canvas(modifier = Modifier.fillMaxSize()) {
                    drawCircle(
                        brush = Brush.radialGradient(tier.gradient, center = center, radius = this.size.minDimension * 0.55f)
                    )
                    drawCircle(
                        color = tier.rimColor,
                        style = Stroke(width = (diameter.value * 0.07f).coerceAtLeast(1.5f))
                    )
                }
            }
        }
    }
}

/** The traveller's own Google photo, cached async -- an initials circle in
 * their own colour while it loads, or if there's no photo to show. */
@Composable
fun AvatarView(url: String?, initial: String, tint: Color, size: androidx.compose.ui.unit.Dp = 36.dp) {
    if (!url.isNullOrBlank()) {
        AsyncImage(
            model = url,
            contentDescription = "Your photo",
            modifier = Modifier.size(size).clip(CircleShape),
            error = null
        )
    } else {
        Surface(modifier = Modifier.size(size), shape = CircleShape, color = tint) {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Text(
                    initial,
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.labelLarge
                )
            }
        }
    }
}

/**
 * The current tier's badge and the next one's, a route line flying between
 * them -- flown so far solid and fading from one tier's colour into the
 * other's, still to go dashed -- with the plane sat wherever that progress
 * actually is, "X/Y flights · X/Y km" written over the line itself, and how
 * many flights this traveller has fed the system written below it. The left
 * end is the traveller's own photo, not a badge -- this is their card, the
 * tier medallion only marks where the route is headed. Rainbow, with
 * nothing beyond it, just shows the badge and its tagline.
 */
@Composable
fun TierProgressCard(
    standing: TierStanding,
    rainbowRank: Int?,
    avatarUrl: String?,
    avatarInitial: String,
    avatarTint: Color,
    flightsFed: Int,
    modifier: Modifier = Modifier
) {
    val tier = standing.tier
    val next = tier.next
    val metric = systemPrefersMetric()

    val fraction = remember(standing) {
        if (tier.legsInBand == Int.MAX_VALUE) 0f
        else {
            val legs = standing.legsIntoTier.toFloat() / tier.legsInBand
            val km = standing.kmIntoTier.toFloat() / tier.kmBudget
            minOf(1f, maxOf(legs, km))
        }
    }
    val progressText = remember(standing, metric) {
        if (tier.legsInBand == Int.MAX_VALUE) tier.tagline
        else {
            val kmText = if (metric) "%,d/%,d km".format(standing.kmIntoTier, tier.kmBudget)
            else "%,d/%,d mi".format(
                (standing.kmIntoTier * 0.621371).toInt(),
                (tier.kmBudget * 0.621371).toInt()
            )
            "${standing.legsIntoTier}/${tier.legsInBand} flights · $kmText"
        }
    }
    val fedText = "$flightsFed ${if (flightsFed == 1) "flight" else "flights"} fed"

    Surface(
        modifier = modifier.fillMaxWidth().heightIn(min = 118.dp, max = 118.dp),
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f),
        tonalElevation = 6.dp
    ) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            AvatarView(url = avatarUrl, initial = avatarInitial, tint = avatarTint, size = 30.dp)
            TierLabel(tier)
            if (next != null) {
                ProgressLine(
                    tier = tier,
                    next = next,
                    fraction = fraction,
                    progressText = progressText,
                    fedText = fedText,
                    modifier = Modifier.weight(1f).fillMaxHeight()
                )
                TierLabel(next)
            } else {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    // Hidden tier, hidden bragging right: which-numbered
                    // traveller ever to get here, once the backend confirms it.
                    if (rainbowRank != null) {
                        Text(
                            "#$rainbowRank",
                            style = MaterialTheme.typography.bodySmall,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Text(tier.tagline, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(fedText, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun TierLabel(tier: MilestoneTier) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        TierBadge(tier, size = 36.dp)
        Text(
            tier.displayName,
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1
        )
    }
}

@Composable
private fun ProgressLine(
    tier: MilestoneTier,
    next: MilestoneTier,
    fraction: Float,
    progressText: String,
    fedText: String,
    modifier: Modifier = Modifier
) {
    val planeColor = tier.rimColor.mixed(next.rimColor, fraction)
    val density = LocalDensity.current
    val remainingColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)

    BoxWithConstraints(modifier = modifier) {
        val widthPx = with(density) { maxWidth.toPx() }
        val flownX = widthPx * fraction

        Canvas(modifier = Modifier.fillMaxSize()) {
            val midY = size.height / 2f
            drawLine(
                color = remainingColor,
                start = Offset(flownX, midY),
                end = Offset(size.width, midY),
                strokeWidth = with(density) { 2.dp.toPx() },
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(with(density) { 5.dp.toPx() }, with(density) { 4.dp.toPx() }))
            )
            if (flownX > 0f) {
                drawLine(
                    brush = Brush.horizontalGradient(listOf(tier.rimColor, planeColor), startX = 0f, endX = flownX.coerceAtLeast(1f)),
                    start = Offset(0f, midY),
                    end = Offset(flownX, midY),
                    strokeWidth = with(density) { 2.5.dp.toPx() }
                )
            }
        }

        val planeXDp = with(density) { flownX.coerceIn(with(density) { 8.dp.toPx() }, widthPx - with(density) { 8.dp.toPx() }).toDp() }
        Icon(
            Icons.Filled.Flight,
            contentDescription = null,
            tint = planeColor,
            modifier = Modifier
                .size(15.dp)
                .align(Alignment.CenterStart)
                .offset(x = planeXDp - 7.dp)
                .rotate(45f)
        )
        Text(
            progressText,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.85f), RoundedCornerShape(4.dp))
                .padding(horizontal = 5.dp, vertical = 1.dp)
        )
        Text(
            fedText,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.align(Alignment.BottomCenter)
        )
    }
}
