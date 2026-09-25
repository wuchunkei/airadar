package com.airadar.app.ui.screens

import com.airadar.app.data.tr

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import com.airadar.app.data.AirlineDatabase
import com.airadar.app.data.AirlineSuggestionStore
import com.airadar.app.data.BackendClient
import com.airadar.app.data.FeedStatus
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightDatabase
import com.airadar.app.data.FlightStatus
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/**
 * For flights no source knows: the traveller types the facts. Airports are
 * resolved by IATA code through the server so the map and zones still work.
 * Doubles as the editor for an existing manual trip — [existing] set means
 * "Save" replaces it rather than adding a new one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualFlightForm(
    flightNumber: String,
    date: LocalDate,
    existing: Flight? = null,
    onAdd: (Flight) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    LaunchedEffect(Unit) { AirlineDatabase.ensureLoaded(context) }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var number by remember { mutableStateOf(existing?.flightNumber ?: flightNumber) }
    var airline by remember { mutableStateOf(existing?.airlineName ?: "") }
    var from by remember { mutableStateOf(existing?.departure ?: "") }
    var to by remember { mutableStateOf(existing?.arrival ?: "") }
    var depTime by remember { mutableStateOf(existing?.departureTime ?: date.atTime(9, 0)) }
    var arrTime by remember { mutableStateOf(existing?.arrivalTime ?: date.atTime(12, 0)) }
    var depTerminal by remember { mutableStateOf(existing?.departureTerminal ?: "") }
    var arrTerminal by remember { mutableStateOf(existing?.arrivalTerminal ?: "") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    var showAirlineConfirm by remember { mutableStateOf(false) }
    var showAirlinePicker by remember { mutableStateOf(false) }
    // What each airport's own terminals turn out to be, once from/to resolves
    // to a known one -- empty means nothing known either way, and the plain
    // text field is still there to type one by hand regardless.
    var depTerminalOptions by remember { mutableStateOf(emptyList<String>()) }
    var arrTerminalOptions by remember { mutableStateOf(emptyList<String>()) }

    // The bundled worldwide table's guess from the flight number's own
    // prefix -- shown until the traveller sets or corrects it.
    val detectedAirline = remember(number) {
        if (number.length < 2) null else AirlineDatabase.airline(number.take(2))?.name
    }
    val shownAirline = airline.ifEmpty { detectedAirline.orEmpty() }

    // A blank field only ever gets filled in once, on the first resolution --
    // never overwritten after that, so editing an existing value is never clobbered.
    LaunchedEffect(from) {
        val options = FlightDatabase.availableTerminals(from)
        depTerminalOptions = options
        if (depTerminal.isEmpty() && options.size == 1) depTerminal = options[0]
    }
    LaunchedEffect(to) {
        val options = FlightDatabase.availableTerminals(to)
        arrTerminalOptions = options
        if (arrTerminal.isEmpty() && options.size == 1) arrTerminal = options[0]
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                if (existing == null) tr("Add manually") else tr("Edit trip"),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )

            SectionLabel(tr("Flight"))
            OutlinedTextField(
                value = number,
                onValueChange = { number = it.uppercase().filter(Char::isLetterOrDigit) },
                label = { Text(tr("Flight number")) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                modifier = Modifier.fillMaxWidth()
            )
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { if (shownAirline.isEmpty()) showAirlinePicker = true else showAirlineConfirm = true }
                    .padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(tr("Airline"))
                Text(shownAirline.ifEmpty { tr("Tap to set") }, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            SectionLabel(tr("Route"))
            RouteRow(tr("From (IATA)"), from, { from = it.uppercase().filter(Char::isLetter).take(3) }, depTerminal, depTerminalOptions) { depTerminal = it }
            RouteRow(tr("To (IATA)"), to, { to = it.uppercase().filter(Char::isLetter).take(3) }, arrTerminal, arrTerminalOptions) { arrTerminal = it }

            SectionLabel(tr("Times (local at each airport)"))
            DateTimeRow(tr("Departure"), depTime) { depTime = it }
            DateTimeRow(tr("Arrival"), arrTime) { arrTime = it }

            error?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text(tr("Cancel")) }
                Button(
                    onClick = {
                        busy = true; error = null
                        val dep = from.uppercase()
                        val arr = to.uppercase()
                        val code = number.uppercase()
                        scope.launch {
                            try {
                                FlightDatabase.ensureAirport(dep) { BackendClient.airport(dep) }
                                FlightDatabase.ensureAirport(arr) { BackendClient.airport(arr) }
                                val a = FlightDatabase.airport(dep)
                                val b = FlightDatabase.airport(arr)
                                if (a == null) { error = tr("Unknown airport %s.", dep); return@launch }
                                if (b == null) { error = tr("Unknown airport %s.", arr); return@launch }
                                val id = "$code-${depTime.toLocalDate()}"
                                val name = shownAirline.ifEmpty { code.take(2) }
                                val status = if (depTime.atZone(a.zone).toInstant().isBefore(Instant.now()))
                                    FlightStatus.COMPLETED else FlightStatus.SCHEDULED
                                val base = existing ?: Flight(
                                    flightNumber = code, departure = dep, arrival = arr,
                                    departureTime = depTime, arrivalTime = arrTime
                                )
                                val callsign = existing?.callsign
                                    ?: FlightDatabase.airlineIcao(code.take(2))?.let { it + code.drop(2) }
                                var f = base.copy(
                                    id = id,
                                    flightNumber = code,
                                    airlineName = name,
                                    departure = dep,
                                    arrival = arr,
                                    departureTerminal = depTerminal.ifEmpty { null },
                                    arrivalTerminal = arrTerminal.ifEmpty { null },
                                    departureTime = depTime,
                                    arrivalTime = arrTime,
                                    status = status,
                                    isManual = true,
                                    callsign = callsign
                                )
                                // A brand-new manual entry is the "feed" moment itself --
                                // the traveller searched, nothing knew this flight, and
                                // they typed it in. Only ever set here, on the very first
                                // save: editing an existing manual trip leaves whatever
                                // verdict it already carries untouched.
                                if (existing == null) f = f.copy(feedStatus = FeedStatus.PENDING)
                                onAdd(f)
                                onDismiss()
                            } finally {
                                busy = false
                            }
                        }
                    },
                    enabled = !busy && number.length >= 3 && from.length == 3 && to.length == 3,
                    modifier = Modifier.weight(1f)
                ) {
                    if (busy) CircularProgressIndicator(modifier = Modifier.height(18.dp).width(18.dp), strokeWidth = 2.dp)
                    else Text(if (existing == null) tr("Add") else tr("Save"), fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }

    // Tapping the shown airline: confirm it's actually right before leaving it
    // alone, so a correct auto-detected guess isn't second-guessed by accident.
    if (showAirlineConfirm) {
        AlertDialog(
            onDismissRequest = { showAirlineConfirm = false },
            title = { Text(tr("Is the airline correct?")) },
            text = { Text(shownAirline) },
            confirmButton = { TextButton(onClick = { showAirlineConfirm = false }) { Text(tr("Yes")) } },
            dismissButton = {
                TextButton(onClick = { showAirlineConfirm = false; showAirlinePicker = true }) { Text(tr("No")) }
            }
        )
    }
    if (showAirlinePicker) {
        AirlinePickerSheet(
            flightNumber = number,
            onSelect = { airline = it; showAirlinePicker = false },
            onDismiss = { showAirlinePicker = false }
        )
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.primary
    )
}

@Composable
private fun RouteRow(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    terminal: String,
    terminalOptions: List<String>,
    onTerminalChange: (String) -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            label = { Text(label) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
            modifier = Modifier.weight(1f)
        )
        TerminalField(terminal, terminalOptions, onTerminalChange)
    }
}

/** One terminal known: forced, nothing to type or pick -- there's no other
 * answer. Several: an actual choice, a menu rather than free text. None
 * known: back to a plain text field, for whatever airport isn't in the
 * hand-checked table yet. */
@Composable
private fun TerminalField(value: String, options: List<String>, onChange: (String) -> Unit) {
    when {
        options.size == 1 -> Text(
            FlightDatabase.terminalDisplayLabel(options[0]),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.widthIn(min = 96.dp)
        )
        options.size > 1 -> {
            var expanded by remember { mutableStateOf(false) }
            Box {
                Row(
                    modifier = Modifier.clickable { expanded = true },
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(if (value.isEmpty()) tr("Choose") else FlightDatabase.terminalDisplayLabel(value))
                    Icon(Icons.Outlined.ArrowDropDown, contentDescription = null)
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    options.forEach { option ->
                        DropdownMenuItem(
                            text = { Text(FlightDatabase.terminalDisplayLabel(option)) },
                            onClick = { onChange(option); expanded = false }
                        )
                    }
                }
            }
        }
        else -> OutlinedTextField(
            value = value,
            onValueChange = onChange,
            label = { Text(tr("Terminal")) },
            singleLine = true,
            modifier = Modifier.width(120.dp)
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateTimeRow(label: String, value: LocalDateTime, onChange: (LocalDateTime) -> Unit) {
    var showDate by remember { mutableStateOf(false) }
    var showTime by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { showDate = true }) { Text(value.toLocalDate().toString()) }
            TextButton(onClick = { showTime = true }) {
                Text(value.toLocalTime().format(DateTimeFormatter.ofPattern("HH:mm")))
            }
        }
    }

    if (showDate) {
        com.airadar.app.ui.components.WheelDatePickerDialog(
            initialDate = value.toLocalDate(),
            onConfirm = { onChange(LocalDateTime.of(it, value.toLocalTime())); showDate = false },
            onDismiss = { showDate = false }
        )
    }
    if (showTime) {
        val state = rememberTimePickerState(initialHour = value.hour, initialMinute = value.minute, is24Hour = true)
        Dialog(onDismissRequest = { showTime = false }) {
            Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 6.dp) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    TimePicker(state = state)
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = { showTime = false }) { Text(tr("Cancel")) }
                        TextButton(onClick = {
                            onChange(LocalDateTime.of(value.toLocalDate(), LocalTime.of(state.hour, state.minute)))
                            showTime = false
                        }) { Text(tr("OK")) }
                    }
                }
            }
        }
    }
}

/** The airline picker: search-as-you-type over the bundled worldwide table,
 * or "Other" for one it doesn't have -- which stages a suggestion rather
 * than just silently accepting whatever was typed. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AirlinePickerSheet(flightNumber: String, onSelect: (String) -> Unit, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }
    var showOther by remember { mutableStateOf(false) }
    val results = remember(query) { AirlineDatabase.search(query) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 480.dp)
                .navigationBarsPadding()
                .padding(horizontal = 20.dp)
        ) {
            Text(
                tr("Airline"),
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(bottom = 12.dp)
            )
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text(tr("Search airline name or code")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Spacer(Modifier.height(8.dp))
            LazyColumn(modifier = Modifier.weight(1f, fill = false)) {
                items(results, key = { it.iata }) { a ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(a.name) }
                            .padding(vertical = 10.dp)
                    ) {
                        Text(a.name)
                        Text(
                            listOfNotNull(a.iata.ifEmpty { null }, a.icao.ifEmpty { null }, a.country.ifEmpty { null })
                                .joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (results.isEmpty() && query.isNotBlank()) {
                    item {
                        Text(
                            tr("No match in the bundled list."),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(vertical = 12.dp)
                        )
                    }
                }
            }
            TextButton(onClick = { showOther = true }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text(tr("Other — my airline isn't listed"))
            }
        }
    }

    if (showOther) {
        OtherAirlineSheet(
            flightNumber = flightNumber,
            onSubmit = { name -> onSelect(name); showOther = false },
            onDismiss = { showOther = false }
        )
    }
}

/** An airline the bundled table doesn't know -- used right away, and staged
 * as a suggestion for a real review later. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OtherAirlineSheet(flightNumber: String, onSubmit: (String) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var name by remember { mutableStateOf("") }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(tr("Suggest an airline"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(tr("e.g. Some New Airline")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Text(
                tr("Not in the bundled list yet — this trip uses the name you type right away, and it's kept on this device to review adding properly later."),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text(tr("Cancel")) }
                Button(
                    onClick = {
                        val trimmed = name.trim()
                        AirlineSuggestionStore.submit(context, flightNumber, trimmed)
                        onSubmit(trimmed)
                    },
                    enabled = name.trim().isNotEmpty(),
                    modifier = Modifier.weight(1f)
                ) { Text(tr("Use this")) }
            }
        }
    }
}
