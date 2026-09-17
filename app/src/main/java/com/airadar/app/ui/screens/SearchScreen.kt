package com.airadar.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DateRange
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Flight
import com.airadar.app.ui.components.WheelDatePickerDialog
import com.airadar.app.ui.components.FlightDetailSheet
import com.airadar.app.ui.viewmodel.SearchViewModel
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun SearchScreen(
    viewModel: SearchViewModel,
    onAddFlight: (Flight) -> Unit,
    modifier: Modifier = Modifier
) {
    val results by viewModel.searchResults.observeAsState(emptyList())
    val isSearching by viewModel.isSearching.observeAsState(false)
    val error by viewModel.error.observeAsState()
    var preview by remember { mutableStateOf<Flight?>(null) }
    // Hoisted (rather than kept inside DetailSearchForm) so a failed search's
    // "Add manually" fallback can hand the same number and date to the form.
    var flightNumber by remember { mutableStateOf("") }
    var date by remember { mutableStateOf(LocalDate.now()) }
    var showManual by remember { mutableStateOf(false) }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .padding(horizontal = 16.dp)
    ) {
        Text(
            "Search",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.padding(vertical = 12.dp)
        )

        Spacer(Modifier.height(8.dp))

        DetailSearchForm(
            flightNumber = flightNumber,
            onFlightNumberChange = { flightNumber = it },
            date = date,
            onDateChange = { date = it },
            isSearching = isSearching,
            onSearch = { viewModel.searchByFlight(flightNumber, date) }
        )

        error?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 14.dp)
            )
            // No source knew it: let the traveller record it by hand -- this is
            // also the "feed" moment the community-review queue picks up.
            TextButton(onClick = { showManual = true }, modifier = Modifier.fillMaxWidth()) {
                Text("Add manually", fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (showManual) {
        ManualFlightForm(
            flightNumber = flightNumber,
            date = date,
            onAdd = { flight ->
                showManual = false
                viewModel.clear()
                onAddFlight(flight)
            },
            onDismiss = { showManual = false }
        )
    }

    // Results open straight into the detail sheet, where the flight can be added.
    LaunchedEffect(results) {
        preview = results.firstOrNull()
    }

    preview?.let { flight ->
        SearchResultSheet(
            flight = flight,
            onAdd = {
                onAddFlight(flight)
                preview = null
                viewModel.clear()
            },
            onDismiss = {
                preview = null
                viewModel.clear()
            }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DetailSearchForm(
    flightNumber: String,
    onFlightNumberChange: (String) -> Unit,
    date: LocalDate,
    onDateChange: (LocalDate) -> Unit,
    isSearching: Boolean,
    onSearch: () -> Unit
) {
    var showPicker by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(
            value = flightNumber,
            onValueChange = { onFlightNumberChange(it.uppercase().filter { c -> c.isLetterOrDigit() }) },
            label = { Text("Flight number") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
            textStyle = MaterialTheme.typography.bodyLarge.copy(
                fontFamily = FontFamily.Monospace,
                letterSpacing = 1.sp
            ),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.fillMaxWidth()
        )

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                    RoundedCornerShape(10.dp)
                )
                .clickable { showPicker = true }
                .padding(horizontal = 16.dp, vertical = 14.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text(
                        "Departure date",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        date.format(DateTimeFormatter.ofPattern("yyyy-MM-dd (EEEE)", Locale.ENGLISH)),
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.Medium
                    )
                }
                Icon(
                    Icons.Outlined.DateRange,
                    contentDescription = "Pick a date",
                    tint = MaterialTheme.colorScheme.primary
                )
            }
        }

        Button(
            onClick = onSearch,
            enabled = flightNumber.length >= 3 && !isSearching,
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(10.dp)
        ) {
            if (isSearching) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = MaterialTheme.colorScheme.onPrimary
                )
            } else {
                Text("Search flight", fontWeight = FontWeight.SemiBold)
            }
        }
    }

    if (showPicker) {
        WheelDatePickerDialog(
            initialDate = date,
            onConfirm = {
                onDateChange(it)
                showPicker = false
            },
            onDismiss = { showPicker = false }
        )
    }
}

@Composable
private fun SearchResultSheet(
    flight: Flight,
    onAdd: () -> Unit,
    onDismiss: () -> Unit
) {
    FlightDetailSheet(
        flight = flight,
        onDismiss = onDismiss,
        primaryAction = "Add to trips" to onAdd
    )
}
