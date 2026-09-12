package com.airadar.app.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.FlightTakeoff
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.rememberCoroutineScope
import com.airadar.app.ui.screens.RecycleBinScreen
import kotlinx.coroutines.launch
import androidx.compose.runtime.LaunchedEffect
import com.airadar.app.data.BackendClient
import com.airadar.app.data.FlightStore
import com.airadar.app.data.Person
import com.airadar.app.ui.components.FlightDetailSheet
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
    MY("My")
}

private enum class Overlay { SETTINGS, EMAIL_IMPORT, RECYCLE_BIN, FRIENDS }

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
    val trackStatus by tripViewModel.trackStatus.observeAsState(emptyMap())
    val context = LocalContext.current
    // Any flight the traveller commits to gets its reminder chain.
    val remind: (Flight) -> Unit = { FlightReminders.schedule(context, it) }
    val settings by settingsViewModel.settings.observeAsState(UserSettings())
    val snackbar = remember { SnackbarHostState() }
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

        null -> Unit
    }

    // A trip someone sent as a link: shown for the traveller to take into Trips.
    var linked by remember { mutableStateOf<Pair<Flight, Person>?>(null) }
    val token by DeepLinks.shareToken
    LaunchedEffect(token) {
        val t = token ?: return@LaunchedEffect
        linked = runCatching { BackendClient.linkedTrip(t) }.getOrNull()
        if (linked == null) {
            snackbar.showSnackbar("That trip link has expired.")
            DeepLinks.shareToken.value = null
        }
    }
    linked?.let { (flight, owner) ->
        FlightDetailSheet(
            flight = flight.copy(airlineName = "${owner.givenName} shared · ${flight.airlineName}"),
            forceSystemZone = settings.forceSystemZone,
            onDismiss = {
                linked = null
                DeepLinks.shareToken.value = null
            },
            primaryAction = "Add to trips" to {
                val t = token
                scope.launch {
                    if (settings.isLoggedIn && t != null) {
                        runCatching { BackendClient.copyLinkedTrip(t) }
                        runCatching { FlightStore.syncFromServer() }
                    } else {
                        tripViewModel.addFlight(flight)
                    }
                    remind(flight)
                    linked = null
                    DeepLinks.shareToken.value = null
                    tab = Tab.TRIP
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
                signedIn = settings.isLoggedIn,
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
                modifier = Modifier.padding(padding)
            )

            Tab.SEARCH -> SearchScreen(
                viewModel = searchViewModel,
                onAddFlight = { flight ->
                    tripViewModel.addFlight(flight)
                    remind(flight)
                    tab = Tab.TRIP
                },
                modifier = Modifier.padding(padding)
            )

            // The map runs edge to edge, so only the nav bar inset is applied.
            Tab.MY -> MyScreen(
                flights = flights,
                forceSystemZone = settings.forceSystemZone,
                trackStatus = trackStatus,
                onLoadTrack = tripViewModel::loadTrack,
                onSettingsClick = { overlay = Overlay.SETTINGS },
                modifier = Modifier.padding(bottom = padding.calculateBottomPadding())
            )
        }
    }
}
