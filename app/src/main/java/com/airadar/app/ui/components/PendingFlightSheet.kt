package com.airadar.app.ui.components

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightDatabase
import com.airadar.app.ui.theme.isDarkTheme
import java.time.format.DateTimeFormatter
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

private const val FEEDBACK_URL = "https://t.me/wuchunkei"

private enum class ReviewStage { REVIEW, EDITING, RESULT }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PendingFlightSheet(
    flight: Flight,
    onConfirm: (Flight) -> Unit,
    onReplace: (Flight, Flight) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val dark = isDarkTheme()

    val correctColor = if (dark) Color(0xFF3FBF87) else Color(0xFF127A4D)
    val wrongColor = if (dark) Color(0xFFFF7A6E) else Color(0xFFC0392B)
    val searchColor = if (dark) Color(0xFF5A9CFF) else Color(0xFF1565D8)
    val feedbackColor = if (dark) Color(0xFFE8B63C) else Color(0xFFB8860B)

    var stage by remember { mutableStateOf(ReviewStage.REVIEW) }
    var editedNumber by remember { mutableStateOf(flight.flightNumber) }
    var editedDate by remember { mutableStateOf(flight.departureTime.toLocalDate()) }
    var showDatePicker by remember { mutableStateOf(false) }
    var candidate by remember { mutableStateOf<Flight?>(null) }
    var searchError by remember { mutableStateOf<String?>(null) }

    // Wrong details turn red and grow, so the two fields to fix are unmistakable.
    val editing = stage != ReviewStage.REVIEW
    val fieldColor by animateColorAsState(
        targetValue = if (editing) wrongColor else MaterialTheme.colorScheme.onSurface,
        label = "fieldColor"
    )
    val fieldScale by animateFloatAsState(
        targetValue = if (editing) 1.25f else 1f,
        label = "fieldScale"
    )

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 20.dp)
                .padding(bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "Imported from email",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary,
                fontWeight = FontWeight.SemiBold
            )

            if (stage == ReviewStage.EDITING) {
                OutlinedTextField(
                    value = editedNumber,
                    onValueChange = {
                        editedNumber = it.uppercase().filter(Char::isLetterOrDigit)
                        searchError = null
                    },
                    label = { Text("Flight number", color = wrongColor) },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.headlineSmall.copy(
                        fontFamily = FontFamily.Monospace,
                        color = wrongColor
                    ),
                    shape = RoundedCornerShape(10.dp),
                    modifier = Modifier.fillMaxWidth()
                )

                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = wrongColor.copy(alpha = 0.08f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { showDatePicker = true }
                ) {
                    Column(modifier = Modifier.padding(14.dp)) {
                        Text(
                            "Departure date",
                            style = MaterialTheme.typography.labelSmall,
                            color = wrongColor
                        )
                        Text(
                            editedDate.format(longDate),
                            style = MaterialTheme.typography.headlineSmall,
                            color = wrongColor,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Bottom
                ) {
                    Column {
                        Text(
                            flight.airlineName.ifBlank { "Airline" },
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            flight.flightNumber,
                            fontSize = (22 * fieldScale).sp,
                            fontWeight = FontWeight.Bold,
                            color = fieldColor
                        )
                    }
                    Text(
                        flight.departureTime.format(longDate),
                        fontSize = (14 * fieldScale).sp,
                        color = fieldColor
                    )
                }

                HorizontalDivider()

                DetailLine("Route", "${flight.departure} → ${flight.arrival}")
                DetailLine(
                    "Departing",
                    "${flight.departureTime.format(clock)} · ${flight.departure}"
                )
                DetailLine(
                    "Arriving",
                    "${flight.arrivalTime.format(clock)} · ${flight.arrival}"
                )
                DetailLine("Duration", formatDuration(flight.durationMinutes))
                flight.aircraft?.let { DetailLine("Aircraft", it) }
            }

            candidate?.let { found ->
                Surface(
                    shape = RoundedCornerShape(12.dp),
                    color = searchColor.copy(alpha = 0.08f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            "Found",
                            style = MaterialTheme.typography.labelSmall,
                            color = searchColor,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            "${found.airlineName} ${found.flightNumber}",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            "${found.departure} ${found.departureTime.format(clock)} → " +
                                    "${found.arrival} ${found.arrivalTime.format(clock)}",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            found.departureTime.format(longDate),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            searchError?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = wrongColor
                )
            }

            when (stage) {
                ReviewStage.REVIEW -> ActionRow(
                    primaryLabel = "Correct",
                    primaryColor = correctColor,
                    onPrimary = { onConfirm(flight) },
                    secondaryLabel = "Incorrect",
                    secondaryColor = wrongColor,
                    onSecondary = { stage = ReviewStage.EDITING }
                )

                ReviewStage.EDITING -> ActionRow(
                    primaryLabel = "Search",
                    primaryColor = searchColor,
                    onPrimary = {
                        val found = FlightDatabase.lookup(editedNumber, editedDate)
                        if (found == null) {
                            searchError = "No schedule for ${editedNumber.uppercase()} on " +
                                    editedDate.format(longDate)
                            candidate = null
                        } else {
                            searchError = null
                            candidate = found
                            stage = ReviewStage.RESULT
                        }
                    },
                    secondaryLabel = "Discard",
                    secondaryColor = wrongColor,
                    onSecondary = {
                        stage = ReviewStage.REVIEW
                        editedNumber = flight.flightNumber
                        editedDate = flight.departureTime.toLocalDate()
                        candidate = null
                        searchError = null
                    }
                )

                ReviewStage.RESULT -> ActionRow(
                    primaryLabel = "Save",
                    primaryColor = correctColor,
                    onPrimary = { candidate?.let { onReplace(flight, it) } },
                    secondaryLabel = "Feedback",
                    secondaryColor = feedbackColor,
                    onSecondary = {
                        context.startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(FEEDBACK_URL))
                        )
                    }
                )
            }
        }
    }

    if (showDatePicker) {
        PendingDatePickerDialog(
            initialDate = editedDate,
            onConfirm = {
                editedDate = it
                showDatePicker = false
                searchError = null
            },
            onDismiss = { showDatePicker = false }
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PendingDatePickerDialog(
    initialDate: LocalDate,
    onConfirm: (LocalDate) -> Unit,
    onDismiss: () -> Unit
) {
    val initialMillis = initialDate.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
    val state = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = {
                val millis = state.selectedDateMillis ?: initialMillis
                val date = java.time.Instant.ofEpochMilli(millis)
                    .atZone(ZoneId.systemDefault())
                    .toLocalDate()
                onConfirm(date)
            }) { Text("OK") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    ) {
        DatePicker(state = state)
    }
}

@Composable
private fun ActionRow(
    primaryLabel: String,
    primaryColor: Color,
    onPrimary: () -> Unit,
    secondaryLabel: String,
    secondaryColor: Color,
    onSecondary: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Button(
            onClick = onSecondary,
            colors = ButtonDefaults.buttonColors(
                containerColor = secondaryColor.copy(alpha = 0.14f),
                contentColor = secondaryColor
            ),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier
                .weight(1f)
                .height(50.dp)
        ) {
            Text(secondaryLabel, fontWeight = FontWeight.SemiBold)
        }

        Button(
            onClick = onPrimary,
            colors = ButtonDefaults.buttonColors(containerColor = primaryColor),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier
                .weight(1f)
                .height(50.dp)
        ) {
            Text(primaryLabel, fontWeight = FontWeight.SemiBold, color = Color.White)
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold
        )
    }
}

private val longDate: DateTimeFormatter = DateTimeFormatter.ofPattern("EEE, d MMM yyyy", Locale.ENGLISH)
private val clock: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
