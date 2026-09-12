package com.airadar.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import java.time.LocalDate
import kotlin.math.abs

private val RowHeight = 40.dp
private const val VisibleRows = 5
// Blank rows above and below the values, so the first and last can reach the middle.
private const val Padding = VisibleRows / 2

@Composable
fun WheelDatePickerDialog(
    initialDate: LocalDate,
    onConfirm: (LocalDate) -> Unit,
    onDismiss: () -> Unit
) {
    var year by remember { mutableIntStateOf(initialDate.year) }
    var month by remember { mutableIntStateOf(initialDate.monthValue) }
    var day by remember { mutableIntStateOf(initialDate.dayOfMonth) }

    val daysInMonth = remember(year, month) { LocalDate.of(year, month, 1).lengthOfMonth() }
    LaunchedEffect(daysInMonth) {
        if (day > daysInMonth) day = daysInMonth
    }

    val currentYear = LocalDate.now().year
    val years = remember { (currentYear - 5..currentYear + 2).toList() }
    val months = remember { (1..12).toList() }
    val days = remember(daysInMonth) { (1..daysInMonth).toList() }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Text(
                    "Select date",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 16.dp, bottom = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ColumnLabel("Year", Modifier.weight(1.2f))
                    ColumnLabel("Month", Modifier.weight(1f))
                    ColumnLabel("Day", Modifier.weight(0.8f))
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(RowHeight * VisibleRows)
                ) {
                    // One band across all three wheels marks the middle row — the
                    // three chosen values always sit side by side on it.
                    Box(
                        modifier = Modifier
                            .align(Alignment.Center)
                            .fillMaxWidth()
                            .height(RowHeight)
                            .background(
                                MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                                RoundedCornerShape(10.dp)
                            )
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Wheel(
                            values = years,
                            selected = year,
                            format = { it.toString() },
                            onSelect = { year = it },
                            modifier = Modifier.weight(1.2f)
                        )
                        Wheel(
                            values = months,
                            selected = month,
                            format = { monthNames[it - 1] },
                            onSelect = { month = it },
                            modifier = Modifier.weight(1f)
                        )
                        Wheel(
                            values = days,
                            selected = day,
                            format = { it.toString() },
                            onSelect = { day = it },
                            modifier = Modifier.weight(0.8f)
                        )
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 12.dp),
                    horizontalArrangement = Arrangement.End
                ) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    TextButton(onClick = { onConfirm(LocalDate.of(year, month, day)) }) {
                        Text("Confirm", fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

@Composable
private fun ColumnLabel(text: String, modifier: Modifier) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        Text(
            text.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            letterSpacing = 0.8.sp
        )
    }
}

/**
 * A snapping wheel. Whatever value stops in the middle row is the selection, so
 * the three wheels always read as one line; tapping a value spins it into place.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Wheel(
    values: List<Int>,
    selected: Int,
    format: (Int) -> String,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier
) {
    val selectedIndex = values.indexOf(selected).coerceAtLeast(0)
    // List index N sits on the top row; with Padding blank rows above the values,
    // that puts value N on the middle row.
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = selectedIndex)
    val scope = rememberCoroutineScope()

    val centeredIndex by remember(values) {
        derivedStateOf {
            val info = listState.layoutInfo
            val middle = (info.viewportStartOffset + info.viewportEndOffset) / 2
            info.visibleItemsInfo
                .minByOrNull { abs(it.offset + it.size / 2 - middle) }
                ?.let { (it.index - Padding).coerceIn(0, values.lastIndex) }
        }
    }

    // Commit only once the wheel has come to rest: pushing the value out on every
    // frame of a fling recomposed the whole dialog mid-spin.
    val currentValues by rememberUpdatedState(values)
    val currentSelected by rememberUpdatedState(selected)
    val currentOnSelect by rememberUpdatedState(onSelect)
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .filter { !it }
            .collect {
                val index = centeredIndex ?: return@collect
                val list = currentValues
                if (index in list.indices && list.indexOf(currentSelected) != index) currentOnSelect(list[index])
            }
    }

    // A change made elsewhere — the day range shrinking when the month changes —
    // spins this wheel to match instead of leaving it on a stale row.
    LaunchedEffect(selectedIndex, values.size) {
        if (centeredIndex != selectedIndex) listState.animateScrollToItem(selectedIndex)
    }

    LazyColumn(
        state = listState,
        flingBehavior = rememberSnapFlingBehavior(listState),
        modifier = modifier.height(RowHeight * VisibleRows),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        items(Padding, key = { "pad-top-$it" }) { Spacer(Modifier.height(RowHeight)) }

        itemsIndexed(values, key = { _, value -> value }) { index, value ->
            // Read inside the draw lambda, so a spin only redraws rows, never
            // recomposes them.
            val isCentered by remember { derivedStateOf { centeredIndex == index } }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(RowHeight)
                    .clickable { scope.launch { listState.animateScrollToItem(index) } }
                    .graphicsLayer {
                        alpha = when (centeredIndex?.let { abs(it - index) } ?: Padding) {
                            0 -> 1f
                            1 -> 0.55f
                            else -> 0.3f
                        }
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    format(value),
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = if (isCentered) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (isCentered) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.onSurface
                )
            }
        }

        items(Padding, key = { "pad-bottom-$it" }) { Spacer(Modifier.height(RowHeight)) }
    }
}

private val monthNames = listOf(
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
)
