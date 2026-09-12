package com.airadar.app

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.airadar.app.data.AuthStore
import com.airadar.app.data.BackendClient
import com.airadar.app.data.FlightStore
import com.airadar.app.data.ThemeMode
import com.airadar.app.data.UserSettings
import com.airadar.app.notifications.FlightReminders
import com.airadar.app.ui.AiradarApp
import com.airadar.app.ui.DeepLinks
import com.airadar.app.ui.theme.AiradarTheme
import com.airadar.app.ui.viewmodel.SettingsViewModel
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val settingsViewModel: SettingsViewModel by viewModels()

    private val askNotifications =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleLink(intent)
    }

    /** airadar://s/<token> or https://<host>/s/<token> — a trip someone shared as a link. */
    private fun handleLink(intent: Intent?) {
        val data = intent?.data ?: return
        val isLink = (data.scheme == "airadar" && data.host == "s") ||
                (data.scheme == "https" && data.pathSegments.firstOrNull() == "s")
        if (isLink) data.lastPathSegment?.let { DeepLinks.shareToken.value = it }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AuthStore.init(this)
        // A returning traveller's trips come down before the list is first shown.
        if (AuthStore.isSignedIn) lifecycleScope.launch {
            runCatching { BackendClient.me() }          // plan and profile as the server sees them
            runCatching { FlightStore.syncFromServer() }
        }
        enableEdgeToEdge()
        FlightReminders.ensureChannels(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        handleLink(intent)
        setContent {
            val settings by settingsViewModel.settings.observeAsState(UserSettings())
            val dark = when (settings.themeMode) {
                ThemeMode.SYSTEM -> isSystemInDarkTheme()
                ThemeMode.LIGHT -> false
                ThemeMode.DARK -> true
            }
            // The status and navigation bar icons must follow the app's theme, not the
            // phone's, or a forced dark app gets dark icons on a dark bar.
            LaunchedEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT)
                    else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
                    navigationBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT)
                    else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                )
            }
            AiradarTheme(darkTheme = dark) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AiradarApp()
                }
            }
        }
    }
}
