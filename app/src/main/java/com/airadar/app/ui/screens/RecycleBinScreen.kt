package com.airadar.app.ui.screens

import com.airadar.app.data.tr

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightStore
import com.airadar.app.ui.components.FlightDetailSheet
import com.airadar.app.ui.viewmodel.TripViewModel
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/**
 * Deleted trips, kept for [FlightStore.RETENTION_DAYS] days. The cards and the
 * detail sheet are the trip list's own; the sheet just ends in a Restore button.
 */
@Composable
fun RecycleBinScreen(
    viewModel: TripViewModel,
    forceSystemZone: Boolean,
    onRestored: (Flight) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val deleted by viewModel.deleted.observeAsState(emptyList())
    var selectedId by remember { mutableStateOf<String?>(null) }
    var confirmRestore by remember { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = tr("Back"))
            }
            Text(
                tr("Recycle Bin"),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
        }

        if (deleted.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    tr("Nothing here. Deleted trips stay for %d days.", FlightStore.RETENTION_DAYS),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                items(deleted, key = { it.id }) { flight ->
                    Column {
                        FlightCard(
                            flight = flight,
                            forceSystemZone = forceSystemZone,
                            onClick = { selectedId = flight.id }
                        )
                        Text(
                            retentionLine(flight.deletedAt),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 4.dp, top = 4.dp)
                        )
                    }
                }
            }
        }
    }

    selectedId?.let { id ->
        val flight = deleted.firstOrNull { it.id == id } ?: return@let
        FlightDetailSheet(
            flight = flight,
            forceSystemZone = forceSystemZone,
            onDismiss = { selectedId = null },
            primaryAction = tr("Restore") to { confirmRestore = true }
        )

        if (confirmRestore) {
            AlertDialog(
                onDismissRequest = { confirmRestore = false },
                title = { Text(tr("Restore this trip?")) },
                text = { Text(tr("%s goes back to your trips, reminders included.", flight.flightNumber)) },
                confirmButton = {
                    TextButton(onClick = {
                        confirmRestore = false
                        selectedId = null
                        viewModel.restoreFlight(flight)
                        onRestored(flight)
                    }) { Text(tr("Confirm")) }
                },
                dismissButton = {
                    TextButton(onClick = { confirmRestore = false }) { Text(tr("Cancel")) }
                }
            )
        }
    }
}

private fun retentionLine(deletedAt: Instant?): String {
    deletedAt ?: return ""
    val daysLeft = (FlightStore.RETENTION_DAYS - Duration.between(deletedAt, Instant.now()).toDays())
        .coerceAtLeast(0)
    val on = deletedAt.atZone(ZoneId.systemDefault()).toLocalDate()
    return if (daysLeft == 1L) tr("Deleted %1\$s · gone for good in 1 day", on)
    else tr("Deleted %1\$s · gone for good in %2\$d days", on, daysLeft)
}
