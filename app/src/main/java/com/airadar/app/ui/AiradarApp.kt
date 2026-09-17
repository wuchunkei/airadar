package com.airadar.app.ui

import android.content.Intent
import android.net.Uri
import com.airadar.app.ui.components.MembershipDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.TextButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.format.DateTimeFormatter
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FlightTakeoff
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.rememberCoroutineScope
import com.airadar.app.ui.screens.CommunityHistoryScreen
import com.airadar.app.ui.screens.CommunityScreen
import com.airadar.app.ui.screens.RecycleBinScreen
import kotlinx.coroutines.launch
import androidx.compose.runtime.LaunchedEffect
import com.airadar.app.data.BackendClient
import com.airadar.app.data.FlightStore
import com.airadar.app.data.Plans
import com.airadar.app.data.TierIconManager
import com.airadar.app.ui.screens.FriendsScreen
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.airadar.app.data.Flight
import com.airadar.app.data.UserSettings
import com.airadar.app.notifications.FlightReminders
import com.airadar.app.ui.screens.EmailImportScreen
import com.airadar.app.ui.screens.MyScreen
import com.airadar.app.ui.screens.SearchScreen
import com.airadar.app.ui.screens.SettingsScreen
import com.airadar.app.ui.screens.TripScreen
import com.airadar.app.ui.viewmodel.SearchViewModel
import com.airadar.app.ui.viewmodel.SettingsViewModel
import com.airadar.app.ui.viewmodel.TripViewModel

private enum class Tab(val label: String) {
    TRIP("Trip"),
    SEARCH("Search"),
    COMMUNITY("Community"),
    MY("My")
}

private enum class Overlay { SETTINGS, EMAIL_IMPORT, RECYCLE_BIN, FRIENDS, COMMUNITY_HISTORY }

/** A trip link opened from outside (airadar://s/<token>); the Activity sets it. */
object DeepLinks {
    val shareToken = mutableStateOf<String?>(null)
}

@Composable
fun AiradarApp() {
    val tripViewModel: TripViewModel = viewModel()
    val searchViewModel: SearchViewModel = viewModel()
    val settingsViewModel: SettingsViewModel = viewModel()

    var tab by remember { mutableStateOf(Tab.TRIP) }
    var overlay by remember { mutableStateOf<Overlay?>(null) }

    val flights by tripViewModel.flights.observeAsState(emptyList())
    val context = LocalContext.current
    // Any flight the traveller commits to gets its reminder chain.
    val remind: (Flight) -> Unit = { FlightReminders.schedule(context, it) }
    val settings by settingsViewModel.settings.observeAsState(UserSettings())
    val snackbar = remember { SnackbarHostState() }

    // The Home Screen icon follows the traveller's tier -- a no-op call
    // whenever it hasn't actually changed (TierIconManager checks first).
    LaunchedEffect(flights) {
        TierIconManager.apply(context, FlightStore.tierStanding.tier)
    }
    val scope = rememberCoroutineScope()

    when (overlay) {
        Overlay.SETTINGS -> {
            SettingsScreen(
                viewModel = settingsViewModel,
                onBackClick = { overlay = null },
                onEmailImportClick = { overlay = Overlay.EMAIL_IMPORT },
                onRecycleBinClick = { overlay = Overlay.RECYCLE_BIN }
            )
            return
        }

        Overlay.EMAIL_IMPORT -> {
            EmailImportScreen(onBack = { overlay = Overlay.SETTINGS })
            return
        }

        Overlay.FRIENDS -> {
            FriendsScreen(onBack = { overlay = null })
            return
        }

        Overlay.RECYCLE_BIN -> {
            RecycleBinScreen(
                viewModel = tripViewModel,
                forceSystemZone = settings.forceSystemZone,
                onRestored = remind,
                onBack = { overlay = Overlay.SETTINGS }
            )
            return
        }

        Overlay.COMMUNITY_HISTORY -> {
            CommunityHistoryScreen(onBack = { overlay = null })
            return
        }

        null -> Unit
    }

    // A plan limit was hit somewhere (search, import, a link): explain, offer more.
    val limitHit by FlightStore.limitHit.observeAsState()
    limitHit?.let { hit ->
        MembershipDialog(
            current = settings.membership.tier,
            reason = hit.reason,
            onDismiss = { FlightStore.clearLimitHit() },
            onGetPlan = {
                FlightStore.clearLimitHit()
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Plans.payUrl)))
            },
            onEnterToken = {
                FlightStore.clearLimitHit()
                overlay = Overlay.SETTINGS
            }
        )
    }

    // A trip someone sent as a link: a small card of the flight, who shared it,
    // and one button to take it into Trips.
    var linked by remember { mutableStateOf<BackendClient.LinkedTrip?>(null) }
    val token by DeepLinks.shareToken
    LaunchedEffect(token) {
        val t = token ?: return@LaunchedEffect
        // A guest does not take part in sharing: the link is simply not recognised.
        if (!settings.isLoggedIn || !settings.membership.limits.sharing) {
            DeepLinks.shareToken.value = null
            return@LaunchedEffect
        }
        linked = runCatching { BackendClient.linkedTrip(t) }.getOrNull()
        if (linked == null) {
            snackbar.showSnackbar("That trip link has expired.")
            DeepLinks.shareToken.value = null
        }
    }
    linked?.let { link ->
        val close = {
            linked = null
            DeepLinks.shareToken.value = null
        }
        LinkedTripDialog(
            link = link,
            onDismiss = close,
            onAdd = {
                val t = token
                scope.launch {
                    val added = if (settings.isLoggedIn && t != null) {
                        runCatching { BackendClient.copyLinkedTrip(t) }.isSuccess
                            .also { runCatching { FlightStore.syncFromServer() } }
                    } else {
                        tripViewModel.addFlight(link.flight)
                    }
                    if (added) {
                        remind(link.flight)
                        tab = Tab.TRIP
                    }
                    close()
                }
            }
        )
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { entry ->
                    NavigationBarItem(
                        selected = tab == entry,
                        onClick = {
                            // Tapping Trip while already on it snaps the list back to today.
                            if (tab == entry && entry == Tab.TRIP) tripViewModel.resetToToday()
                            tab = entry
                        },
                        icon = {
                            Icon(
                                when (entry) {
                                    Tab.TRIP -> Icons.Outlined.FlightTakeoff
                                    Tab.SEARCH -> Icons.Outlined.Search
                                    Tab.COMMUNITY -> Icons.Outlined.Groups
                                    Tab.MY -> Icons.Outlined.Map
                                },
                                contentDescription = entry.label
                            )
                        },
                        label = { Text(entry.label) }
                    )
                }
            }
        }
    ) { padding ->
        when (tab) {
            Tab.TRIP -> TripScreen(
                viewModel = tripViewModel,
                forceSystemZone = settings.forceSystemZone,
                onCommitted = remind,
                onFriendsClick = { overlay = Overlay.FRIENDS },
                onCreateFirst = { tab = Tab.SEARCH },
                // Friends and sharing are for plan holders; a guest sees neither.
                signedIn = settings.isLoggedIn && settings.membership.limits.sharing,
                onDeleted = { flight ->
                    FlightReminders.cancel(context, flight.id)
                    scope.launch {
                        snackbar.currentSnackbarData?.dismiss()
                        snackbar.showSnackbar(
                            "Moved to the Recycle Bin. Restore it from My › Settings › Recycle Bin " +
                                    "within 30 days."
                        )
                    }
                },
                // Each screen applies the status bar inset itself; only the nav bar is shared.
                modifier = Modifier.padding(bottom = padding.calculateBottomPadding())
            )

            Tab.SEARCH -> SearchScreen(
                viewModel = searchViewModel,
                onAddFlight = { flight ->
                    // A refusal opens the plans dialog by itself; stay on Search then.
                    if (tripViewModel.addFlight(flight)) {
                        remind(flight)
                        tab = Tab.TRIP
                    }
                },
                // Each screen applies the status bar inset itself; only the nav bar is shared.
                modifier = Modifier.padding(bottom = padding.calculateBottomPadding())
            )

            Tab.COMMUNITY -> CommunityScreen(
                onHistoryClick = { overlay = Overlay.COMMUNITY_HISTORY },
                modifier = Modifier.padding(bottom = padding.calculateBottomPadding())
            )

            // The map runs edge to edge, so only the nav bar inset is applied.
            Tab.MY -> MyScreen(
                flights = flights,
                forceSystemZone = settings.forceSystemZone,
                onLoadTrack = tripViewModel::loadTrack,
                onSettingsClick = { overlay = Overlay.SETTINGS },
                modifier = Modifier.padding(bottom = padding.calculateBottomPadding())
            )
        }
    }
}

@Composable
private fun LinkedTripDialog(link: BackendClient.LinkedTrip, onDismiss: () -> Unit, onAdd: () -> Unit) {
    val f = link.flight
    val clock = DateTimeFormatter.ofPattern("HH:mm")
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Column {
                Text(f.flightNumber, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                Text(f.airlineName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        text = {
            Column {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column {
                        Text(f.departure, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                        Text(f.departureAirport?.city ?: "", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text("→", style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.primary)
                    Column(horizontalAlignment = Alignment.End) {
                        Text(f.arrival, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                        Text(f.arrivalAirport?.city ?: "", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Text(
                    "${f.departureTime.toLocalDate()} · ${f.departureTime.format(clock)} → ${f.arrivalTime.format(clock)}",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 12.dp)
                )
                Row(modifier = Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(22.dp)
                            .background(link.owner.tint, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(link.ownerName.take(1).uppercase(), color = Color.White,
                            style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
                    }
                    Text(
                        "Shared by ${link.ownerName}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = link.owner.tint,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(start = 8.dp)
                    )
                }
            }
        },
        confirmButton = { Button(onClick = onAdd) { Text("Add to trips") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } }
    )
}
