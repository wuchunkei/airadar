package com.airadar.app.ui.components

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.airadar.app.data.Airport
import com.airadar.app.data.Flight
import java.time.Duration
import java.time.Instant

/** A map app the traveller might have, with how to ask it for driving directions. */
enum class MapProvider(val label: String, val packageName: String?) {
    GOOGLE("Google Maps", "com.google.android.apps.maps"),
    AMAP("Amap", "com.autonavi.minimap"),
    WAZE("Waze", "com.waze"),
    OTHER("Other map app", null);

    fun isInstalled(context: Context): Boolean {
        val pkg = packageName ?: return true
        return runCatching { context.packageManager.getPackageInfo(pkg, 0) }.isSuccess
    }

    fun open(context: Context, airport: Airport) {
        val lat = airport.latitude
        val lon = airport.longitude
        val name = Uri.encode(airport.iata)
        val uri = when (this) {
            GOOGLE -> "google.navigation:q=$lat,$lon&mode=d"
            AMAP -> "amapuri://route/plan/?dlat=$lat&dlon=$lon&dname=$name&dev=0&t=0&sourceApplication=Airadar"
            WAZE -> "waze://?ll=$lat,$lon&navigate=yes"
            OTHER -> "geo:$lat,$lon?q=$lat,$lon($name)"
        }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        packageName?.let { intent.setPackage(it) }
        runCatching { context.startActivity(intent) }
    }

    companion object {
        /** Every provider installed, the generic "other" last. */
        fun available(context: Context): List<MapProvider> = entries.filter { it.isInstalled(context) }
    }
}

/** Navigation is offered for the departure airport only in the day before it leaves. */
fun Flight.canNavigateToDeparture(now: Instant = Instant.now()): Boolean {
    val dep = departureInstant ?: return false
    val left = Duration.between(now, dep)
    return !left.isNegative && left < Duration.ofHours(24) && departureAirport != null
}

/** The bottom sheet: which map app to navigate to the departure airport with. Text rows only. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapChooserSheet(airport: Airport, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val providers = remember { MapProvider.available(context) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 16.dp)
                .navigationBarsPadding()
        ) {
            Text("Navigate to ${airport.iata}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                airport.name, style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1
            )
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                modifier = Modifier.padding(top = 16.dp)
            ) {
                Column {
                    providers.forEachIndexed { i, provider ->
                        Text(
                            provider.label,
                            style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    provider.open(context, airport)
                                    onDismiss()
                                }
                                .padding(horizontal = 16.dp, vertical = 14.dp)
                        )
                        if (i < providers.size - 1) HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}
