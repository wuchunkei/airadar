package com.airadar.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

private val sheetDate: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd (EEEE)", Locale.ENGLISH)

/**
 * Date picking as a bottom sheet: the chosen day in large type, three one-tap
 * shortcuts, and a bare month grid underneath — no dialog chrome, no mode toggle.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DateSheet(
    initialDate: LocalDate,
    onConfirm: (LocalDate) -> Unit,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val pickerState = rememberDatePickerState(initialSelectedDateMillis = initialDate.toMillis())
    var chosen by remember { mutableStateOf(initialDate) }

    // The grid drives the headline; the shortcut chips drive the grid.
    LaunchedEffect(pickerState) {
        snapshotFlow { pickerState.selectedDateMillis }.collect { millis ->
            millis?.let { chosen = it.toLocalDate() }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .navigationBarsPadding()
        ) {
            Text(
                "Departure date",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                chosen.format(sheetDate),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 2.dp)
            )

            val today = LocalDate.now()
            Row(
                modifier = Modifier.padding(top = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf(
                    "Today" to today,
                    "Tomorrow" to today.plusDays(1),
                    "In a week" to today.plusDays(7)
                ).forEach { (label, day) ->
                    FilterChip(
                        selected = chosen == day,
                        onClick = {
                            pickerState.selectedDateMillis = day.toMillis()
                            pickerState.displayedMonthMillis = day.withDayOfMonth(1).toMillis()
                        },
                        label = { Text(label) }
                    )
                }
            }

            DatePicker(
                state = pickerState,
                title = null,
                headline = null,
                showModeToggle = false,
                modifier = Modifier.padding(top = 4.dp)
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 12.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = onDismiss) { Text("Cancel") }
                Spacer(Modifier.height(0.dp).padding(horizontal = 4.dp))
                Button(onClick = { onConfirm(chosen) }) { Text("Done") }
            }
        }
    }
}

private fun LocalDate.toMillis(): Long = atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()

private fun Long.toLocalDate(): LocalDate = Instant.ofEpochMilli(this).atZone(ZoneOffset.UTC).toLocalDate()
