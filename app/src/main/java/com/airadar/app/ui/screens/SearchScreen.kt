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

private enum class SearchMode(val label: String) {
    DETAIL("Detail"),
    PNR("PNR")
}

@Composable
fun SearchScreen(
    viewModel: SearchViewModel,
    onAddFlight: (Flight) -> Unit,
    modifier: Modifier = Modifier
) {
    var mode by remember { mutableStateOf(SearchMode.DETAIL) }
    val results by viewModel.searchResults.observeAsState(emptyList())
    val isSearching by viewModel.isSearching.observeAsState(false)
    val error by viewModel.error.observeAsState()
    var preview by remember { mutableStateOf<Flight?>(null) }

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

        Row(modifier = Modifier.fillMaxWidth()) {
            SearchMode.entries.forEach { entry ->
                val selected = entry == mode
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .clickable {
                            mode = entry
                            viewModel.clear()
                        },
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        entry.label,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (selected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 12.dp)
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(2.dp)
                            .background(
                                if (selected) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.outlineVariant
                            )
                    )
                }
            }
        }

        Spacer(Modifier.height(20.dp))

        when (mode) {
            SearchMode.DETAIL -> DetailSearchForm(
                isSearching = isSearching,
                onSearch = { number, date -> viewModel.searchByFlight(number, date) }
            )

            SearchMode.PNR -> PnrSearchForm(
                isSearching = isSearching,
                onSearch = { pnr, lastName -> viewModel.searchByPnr(pnr, lastName) }
            )
        }

        error?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(top = 14.dp)
            )
        }
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
    isSearching: Boolean,
    onSearch: (String, LocalDate) -> Unit
) {
    var flightNumber by remember { mutableStateOf("") }
    var date by remember { mutableStateOf(LocalDate.now()) }
    var showPicker by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(
            value = flightNumber,
            onValueChange = { flightNumber = it.uppercase().filter { c -> c.isLetterOrDigit() } },
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
            onClick = { onSearch(flightNumber, date) },
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
                date = it
                showPicker = false
            },
            onDismiss = { showPicker = false }
        )
    }
}

@Composable
private fun PnrSearchForm(
    isSearching: Boolean,
    onSearch: (String, String) -> Unit
) {
    var pnr by remember { mutableStateOf("") }
    var lastName by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        OutlinedTextField(
            value = pnr,
            onValueChange = { pnr = it.uppercase().filter { c -> c.isLetterOrDigit() }.take(8) },
            label = { Text("Booking reference") },
            placeholder = { Text("ABC123") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
            textStyle = MaterialTheme.typography.bodyLarge.copy(
                fontFamily = FontFamily.Monospace,
                letterSpacing = 2.sp
            ),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.fillMaxWidth()
        )

        OutlinedTextField(
            value = lastName,
            onValueChange = { lastName = it },
            label = { Text("Last name") },
            placeholder = { Text("As printed on the ticket") },
            singleLine = true,
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.fillMaxWidth()
        )

        Button(
            onClick = { onSearch(pnr, lastName) },
            enabled = pnr.length >= 5 && lastName.isNotBlank() && !isSearching,
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
                Text("Find booking", fontWeight = FontWeight.SemiBold)
            }
        }

        Text(
            "The booking reference is the six-character code on your confirmation email.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
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
