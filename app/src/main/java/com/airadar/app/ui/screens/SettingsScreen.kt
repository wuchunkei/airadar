package com.airadar.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.ThemeMode
import com.airadar.app.data.UserSettings
import com.airadar.app.ui.viewmodel.SettingsViewModel

@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel,
    onBackClick: () -> Unit,
    onEmailImportClick: () -> Unit,
    onRecycleBinClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val settings by viewModel.settings.observeAsState(UserSettings())
    val authError by viewModel.authError.observeAsState()
    val signingIn by viewModel.signingIn.observeAsState(false)
    val activity = LocalContext.current
    val calendarStatus by viewModel.calendarStatus.observeAsState()
    val askCalendar = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) viewModel.setCalendarSync(true)
    }

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
            IconButton(onClick = onBackClick) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
            }
            Text(
                "Settings",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                SettingsSection("Account") {
                    if (settings.isLoggedIn) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    settings.userName ?: "Signed in",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    settings.userEmail ?: "",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            TextButton(onClick = viewModel::signOut) { Text("Sign out") }
                        }
                    } else {
                        Text(
                            "Keep your trips on every device and in the recycle bin for 30 days.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Button(
                            onClick = { viewModel.signIn(activity) },
                            enabled = !signingIn,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 12.dp)
                                .height(48.dp),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            if (signingIn) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    strokeWidth = 2.dp,
                                    color = MaterialTheme.colorScheme.onPrimary
                                )
                            } else {
                                Text("Continue with Google", fontWeight = FontWeight.SemiBold)
                            }
                        }
                        authError?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(top = 8.dp)
                            )
                        }
                    }
                }
            }

            item {
                SettingsSection("Import") {
                    NavigationRow(
                        title = "Read trips from email",
                        onClick = onEmailImportClick
                    )
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    ToggleRow(
                        title = "Read trips from calendar",
                        checked = settings.calendarSyncEnabled,
                        onCheckedChange = { on ->
                            if (!on) viewModel.setCalendarSync(false)
                            else if (ContextCompat.checkSelfPermission(activity, Manifest.permission.READ_CALENDAR) ==
                                PackageManager.PERMISSION_GRANTED
                            ) viewModel.setCalendarSync(true)
                            else askCalendar.launch(Manifest.permission.READ_CALENDAR)
                        }
                    )
                    calendarStatus?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }

            item {
                SettingsSection("Display") {
                    AppearanceRow(
                        mode = settings.themeMode,
                        onModeChange = viewModel::setThemeMode
                    )
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    ToggleRow(
                        title = "Show times in my time zone",
                        checked = settings.forceSystemZone,
                        onCheckedChange = viewModel::setForceSystemZone
                    )
                }
            }

            item {
                SettingsSection("Trips") {
                    NavigationRow(
                        title = "Recycle Bin",
                        onClick = onRecycleBinClick
                    )
                }
            }

            item {
                SettingsSection("About") {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("Version", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            "1.0.0",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Column {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp,
            modifier = Modifier.padding(start = 4.dp, bottom = 8.dp)
        )
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(14.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
        ) {
            Column(modifier = Modifier.padding(16.dp)) { content() }
        }
    }
}

@Composable
private fun NavigationRow(
    title: String,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium
            )
        }
        Icon(
            Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** System / Light / Dark, as a segmented control under its own label. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AppearanceRow(mode: ThemeMode, onModeChange: (ThemeMode) -> Unit) {
    Column(modifier = Modifier.padding(vertical = 6.dp)) {
        Text("Appearance", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp)
        ) {
            val modes = ThemeMode.entries
            modes.forEachIndexed { index, entry ->
                SegmentedButton(
                    selected = mode == entry,
                    onClick = { onModeChange(entry) },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = modes.size)
                ) {
                    Text(
                        when (entry) {
                            ThemeMode.SYSTEM -> "System"
                            ThemeMode.LIGHT -> "Light"
                            ThemeMode.DARK -> "Dark"
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun ToggleRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium
            )
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
