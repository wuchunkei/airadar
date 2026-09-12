package com.airadar.app.ui.viewmodel

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import com.airadar.app.data.ThemeMode
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.airadar.app.data.Flight
import com.airadar.app.data.BackendClient
import com.airadar.app.data.FlightDatabase
import com.airadar.app.data.FlightPhase
import com.airadar.app.data.FlightStore
import com.airadar.app.data.OpenSkyClient
import com.airadar.app.data.TravelStats
import com.airadar.app.data.UserSettings
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.LocalDate

sealed interface TrackStatus {
    data object Loading : TrackStatus
    data class Failed(val reason: String) : TrackStatus
}

class TripViewModel : ViewModel() {

    val flights: LiveData<List<Flight>> = FlightStore.flights
    val deleted: LiveData<List<Flight>> = FlightStore.deleted

    private val _trackStatus = MutableLiveData<Map<String, TrackStatus>>(emptyMap())
    val trackStatus: LiveData<Map<String, TrackStatus>> = _trackStatus

    private val _showHistory = MutableLiveData(false)
    val showHistory: LiveData<Boolean> = _showHistory

    private val _isRefreshing = MutableLiveData(false)
    val isRefreshing: LiveData<Boolean> = _isRefreshing

    var resetSignal by mutableIntStateOf(0)
        private set

    fun refresh() {
        if (_isRefreshing.value == true) return
        viewModelScope.launch {
            _isRefreshing.value = true
            delay(900)
            FlightStore.reseed()
            _isRefreshing.value = false
        }
    }

    /** Unlocks scrolling up into the past trips that sit above the present. */
    fun revealHistory() {
        _showHistory.value = true
    }

    fun hideHistory() {
        _showHistory.value = false
    }

    /** Tapping the Trip tab again returns the list to today. */
    fun resetToToday() {
        _showHistory.value = false
        resetSignal++
    }

    fun addFlight(flight: Flight) = FlightStore.add(flight)

    fun confirmPending(flight: Flight) = FlightStore.confirm(flight)

    fun deleteFlight(flight: Flight) = FlightStore.delete(flight.id)

    fun restoreFlight(flight: Flight) = FlightStore.restore(flight.id)

    fun replacePending(old: Flight, replacement: Flight) = FlightStore.replace(old, replacement)

    /** Fetches the ADS-B track for a flown leg; the result lands in the store. */
    fun loadTrack(flight: Flight) {
        if (_trackStatus.value?.get(flight.id) is TrackStatus.Loading) return
        viewModelScope.launch {
            setTrackStatus(flight.id, TrackStatus.Loading)
            try {
                val fetched = OpenSkyClient.fetchTrack(flight)
                FlightStore.setTrack(flight.id, fetched.points, fetched.flownOn)
                setTrackStatus(flight.id, null)
            } catch (e: IOException) {
                setTrackStatus(flight.id, TrackStatus.Failed(e.message ?: "Network error"))
            }
        }
    }

    private fun setTrackStatus(flightId: String, status: TrackStatus?) {
        val next = _trackStatus.value.orEmpty().toMutableMap()
        if (status == null) next.remove(flightId) else next[flightId] = status
        _trackStatus.value = next
    }

}

class SearchViewModel : ViewModel() {

    private val _searchResults = MutableLiveData<List<Flight>>(emptyList())
    val searchResults: LiveData<List<Flight>> = _searchResults

    private val _isSearching = MutableLiveData(false)
    val isSearching: LiveData<Boolean> = _isSearching

    private val _error = MutableLiveData<String?>(null)
    val error: LiveData<String?> = _error

    fun searchByFlight(flightNumber: String, date: LocalDate) {
        viewModelScope.launch {
            _isSearching.value = true
            _error.value = null
            try {
                // The server decides between live status and a timetable row.
                _searchResults.value = listOf(BackendClient.flight(flightNumber, date))
            } catch (e: IOException) {
                _searchResults.value = emptyList()
                _error.value = e.message
            }
            _isSearching.value = false
        }
    }

    fun searchByPnr(pnr: String, lastName: String) {
        viewModelScope.launch {
            _isSearching.value = true
            _error.value = null
            delay(400)
            val matches = FlightDatabase.lookupByPnr(pnr, lastName)
            _searchResults.value = matches
            if (matches.isEmpty()) {
                _error.value = "Booking lookup isn't connected yet. " +
                        "It needs an airline or GDS account — no open service returns " +
                        "a booking from a reference alone. Search by flight number meanwhile."
            }
            _isSearching.value = false
        }
    }

    fun clear() {
        _searchResults.value = emptyList()
        _error.value = null
    }
}

class SettingsViewModel(app: Application) : AndroidViewModel(app) {

    private val prefs = app.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private val _settings = MutableLiveData(
        UserSettings(
            calendarSyncEnabled = prefs.getBoolean("calendarSync", false),
            forceSystemZone = prefs.getBoolean("forceSystemZone", false),
            themeMode = prefs.getString("themeMode", null)
                ?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() }
                ?: ThemeMode.SYSTEM
        )
    )
    val settings: LiveData<UserSettings> = _settings

    fun signIn() {
        _settings.value = _settings.value?.copy(
            isLoggedIn = true,
            userName = "Traveller",
            userEmail = "you@example.com"
        )
    }

    fun signOut() {
        _settings.value = UserSettings()
    }

    fun setCalendarSync(enabled: Boolean) {
        prefs.edit().putBoolean("calendarSync", enabled).apply()
        _settings.value = _settings.value?.copy(calendarSyncEnabled = enabled)
    }

    fun setForceSystemZone(enabled: Boolean) {
        prefs.edit().putBoolean("forceSystemZone", enabled).apply()
        _settings.value = _settings.value?.copy(forceSystemZone = enabled)
    }

    fun setThemeMode(mode: ThemeMode) {
        prefs.edit().putString("themeMode", mode.name).apply()
        _settings.value = _settings.value?.copy(themeMode = mode)
    }

}

fun List<Flight>.travelStats(): TravelStats {
    val completed = filter { it.phase == FlightPhase.PAST && !it.isPending }
    val airports = completed.flatMap { listOfNotNull(it.departureAirport, it.arrivalAirport) }
    return TravelStats(
        totalDistanceKm = completed.sumOf { it.distanceKm },
        flightCount = completed.size,
        countryCount = airports.map { it.country }.distinct().size,
        cityCount = airports.map { it.city }.distinct().size
    )
}
