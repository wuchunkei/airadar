package com.airadar.app.ui.components

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.airadar.app.data.BackendClient
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightStore
import com.airadar.app.data.Friend
import com.airadar.app.data.FriendStatus
import com.airadar.app.data.ShareStatus
import kotlinx.coroutines.launch

/**
 * Share one of my trips: straight to friends (they get a card to accept, reject
 * or take together), or as a link — copied, or handed to any other app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareSheet(flight: Flight, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var friends by remember { mutableStateOf<List<Friend>>(emptyList()) }
    var chosen by remember { mutableStateOf<Set<String>>(emptySet()) }
    var note by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        friends = runCatching { BackendClient.friends() }.getOrDefault(emptyList())
            .filter { it.status == FriendStatus.ACCEPTED }
    }
    val alreadyShared = flight.shares.associate { it.person.id to it.status }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
        ) {
            Text(
                "Share ${flight.flightNumber}",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                "${flight.departure} → ${flight.arrival} · ${flight.departureTime.toLocalDate()}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Text(
                "Friends",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 20.dp, bottom = 6.dp)
            )
            if (friends.isEmpty()) {
                Text(
                    "No friends yet — add some from the Friends page.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            friends.forEach { f ->
                val status = alreadyShared[f.person.id]
                val selected = f.person.id in chosen
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .then(
                            if (status == null) Modifier.clickable {
                                chosen = if (selected) chosen - f.person.id else chosen + f.person.id
                            } else Modifier
                        )
                        .padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .background(f.person.tint, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        if (selected) Icon(Icons.Outlined.Check, contentDescription = null, tint = Color.White)
                        else Text(f.person.givenName.take(1).uppercase(), color = Color.White, fontWeight = FontWeight.Bold)
                    }
                    Text(
                        f.person.givenName,
                        style = MaterialTheme.typography.bodyLarge,
                        color = f.person.tint,
                        modifier = Modifier
                            .weight(1f)
                            .padding(start = 12.dp)
                    )
                    status?.let {
                        Text(
                            it.label(),
                            style = MaterialTheme.typography.labelMedium,
                            color = it.blockColor()
                        )
                    }
                }
            }
            if (friends.isNotEmpty()) {
                Button(
                    onClick = {
                        scope.launch {
                            sending = true
                            val people = friends.filter { it.person.id in chosen }.map { it.person }
                            people.forEach { runCatching { FlightStore.shareWith(flight, it) } }
                            sending = false
                            onDismiss()
                        }
                    },
                    enabled = chosen.isNotEmpty() && !sending,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp)
                        .height(46.dp),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text(
                        if (chosen.size <= 1) "Send to friend" else "Send to ${chosen.size} friends",
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }

            HorizontalDivider(Modifier.padding(vertical = 16.dp))

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            mintLink(flight)?.let { url ->
                                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                clipboard.setPrimaryClip(ClipData.newPlainText("Airadar trip", url))
                                note = "Link copied."
                            } ?: run { note = "Could not create a link." }
                        }
                    },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp)
                ) { Text("Copy link") }
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            mintLink(flight)?.let { url ->
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_SUBJECT, "${flight.flightNumber} ${flight.departure} → ${flight.arrival}")
                                    putExtra(
                                        Intent.EXTRA_TEXT,
                                        "${flight.flightNumber} ${flight.departure} → ${flight.arrival} on " +
                                                "${flight.departureTime.toLocalDate()}\n$url"
                                    )
                                }
                                context.startActivity(Intent.createChooser(send, "Share trip"))
                            } ?: run { note = "Could not create a link." }
                        }
                    },
                    modifier = Modifier.weight(1f),
                    shape = RoundedCornerShape(12.dp)
                ) { Text("Share via…") }
            }
            note?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(top = 8.dp, bottom = 12.dp)
                )
            }
        }
    }
}

private suspend fun mintLink(flight: Flight): String? =
    runCatching { BackendClient.shareTrip(flight.id).second?.let { BackendClient.linkUrl(it) } }.getOrNull()

fun ShareStatus.label(): String = when (this) {
    ShareStatus.PENDING -> "Pending"
    ShareStatus.ACCEPTED -> "Accepted"
    ShareStatus.REJECTED -> "Rejected"
    ShareStatus.TOGETHER -> "Together"
}

/** The block colours the traveller asked for: yellow, grey, green, red. */
fun ShareStatus.blockColor(): Color = when (this) {
    ShareStatus.TOGETHER -> Color(0xFFF9A825)
    ShareStatus.PENDING -> Color(0xFF9E9E9E)
    ShareStatus.ACCEPTED -> Color(0xFF43A047)
    ShareStatus.REJECTED -> Color(0xFFE53935)
}
