package com.airadar.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.airadar.app.data.BackendClient
import com.airadar.app.data.CommunityReview
import kotlinx.coroutines.launch
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * A fed flight the automated scorer (backend/app/feed.py) couldn't settle
 * either way waits here for other travellers to vote real/not-real on --
 * never my own submissions, never one I've already voted on. History (the
 * clock icon, where Friends sat on the old separate Past tab) is the only
 * toolbar item here; Community has no Friends button of its own.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommunityScreen(onHistoryClick: () -> Unit, modifier: Modifier = Modifier) {
    var reviews by remember { mutableStateOf<List<CommunityReview>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var reloadSignal by remember { mutableStateOf(0) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        loading = true
        try {
            reviews = BackendClient.communityQueue()
            error = null
        } catch (e: Exception) {
            error = e.message ?: "Couldn't load the review queue."
        }
        loading = false
    }

    LaunchedEffect(reloadSignal) { load() }

    Column(modifier = modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Community") },
            actions = {
                IconButton(onClick = { reloadSignal++ }) {
                    Icon(Icons.Outlined.Refresh, contentDescription = "Refresh")
                }
                IconButton(onClick = onHistoryClick) {
                    Icon(Icons.Outlined.History, contentDescription = "History")
                }
            }
        )

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            error != null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(error ?: "", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = { reloadSignal++ }) { Text("Try again") }
                }
            }
            reviews.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    "Nothing to review right now.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            else -> LazyColumn(
                contentPadding = PaddingValues(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(reviews, key = { it.id }) { review ->
                    CommunityReviewCard(
                        review = review,
                        onVote = { approve ->
                            // Optimistic: gone from this queue the moment the tap
                            // lands, since one vote per person is all this ever allows.
                            reviews = reviews.filterNot { it.id == review.id }
                            scope.launch { runCatching { BackendClient.voteOnReview(review.id, approve) } }
                        }
                    )
                }
            }
        }
    }
}

/** Flight facts plus a two-button footer and the live tally; [onVote] null
 * shows a read-only status pill instead -- used by History. */
@Composable
fun CommunityReviewCard(review: CommunityReview, onVote: ((Boolean) -> Unit)? = null) {
    Card(
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.94f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    review.airlineName.ifBlank { "—" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    review.flightNumber,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            Row(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(review.departure, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(
                        review.departureAirport?.city ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowForward,
                    contentDescription = null,
                    modifier = Modifier.padding(top = 6.dp, start = 8.dp, end = 8.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
                Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.End) {
                    Text(review.arrival, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                    Text(
                        review.arrivalAirport?.city ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            Text(
                "${review.departureTime.toLocalDate()} · ${review.departureTime.format(clockFormat)} → ${review.arrivalTime.format(clockFormat)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${review.approveCount} approve · ${review.rejectCount} reject",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (review.boosted) {
                    Text(
                        " · needs more votes",
                        style = MaterialTheme.typography.labelMedium,
                        color = Color(0xFFFF9800)
                    )
                }
                Spacer(Modifier.weight(1f))
                review.myVote?.let { vote ->
                    Text(
                        if (vote) "You: Approved" else "You: Rejected",
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.SemiBold,
                        color = if (vote) Color(0xFF2E7D32) else Color(0xFFE53935)
                    )
                }
            }
            if (onVote != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    Button(
                        onClick = { onVote(true) },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2E7D32)),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Outlined.Check, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Looks real")
                    }
                    Button(
                        onClick = { onVote(false) },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE53935)),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Doesn't look real")
                    }
                }
            } else {
                StatusPill(review.status)
            }
        }
    }
}

/** Pending (secondary) / Confirmed (green) / Rejected (red) / Expired (orange). */
@Composable
fun StatusPill(status: String) {
    val color = when (status) {
        "confirmed" -> Color(0xFF2E7D32)
        "rejected" -> Color(0xFFE53935)
        "expired" -> Color(0xFFFF9800)
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(color = color.copy(alpha = 0.14f), shape = RoundedCornerShape(6.dp)) {
        Text(
            status.replaceFirstChar { it.uppercase(Locale.ROOT) },
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = color,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
        )
    }
}

private val clockFormat: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
