package com.airadar.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.airadar.app.data.Plans
import com.airadar.app.data.Tier

private class PlanRow(val feature: String, val guest: String, val superior: String, val premium: String)

private val rows = listOf(
    PlanRow("Trips kept", "3", "Unlimited", "Unlimited"),
    PlanRow("Past trips", "1", "5", "Unlimited"),
    PlanRow("Add ahead", "7 days", "30 days", "Any date"),
    PlanRow("Cloud sync", "—", "✓", "✓"),
    PlanRow("Friends & sharing", "—", "✓", "✓"),
    PlanRow("Recycle bin", "—", "✓", "✓"),
    PlanRow("Past flight lookup", "—", "—", "✓"),
    PlanRow("Flown tracks", "—", "—", "✓"),
    PlanRow("Gmail & calendar import", "—", "—", "✓"),
    PlanRow("Price", "Free", Plans.SUPERIOR_PRICE, Plans.PREMIUM_PRICE)
)

/**
 * Guest / Superior / Premium side by side. Shown before sign-in (with the Google
 * button), from Settings (with subscribe buttons), and whenever a plan limit is
 * hit (with the reason on top).
 */
@Composable
fun MembershipDialog(
    current: Tier,
    reason: String? = null,
    onDismiss: () -> Unit,
    onSignIn: (() -> Unit)? = null,
    onSubscribe: ((productId: String) -> Unit)? = null,
    busy: Boolean = false
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Plans", fontWeight = FontWeight.Bold) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                reason?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(bottom = 12.dp)
                    )
                }
                Row(modifier = Modifier.fillMaxWidth()) {
                    Cell("", Modifier.weight(1.4f), header = true)
                    Cell("Guest", Modifier.weight(1f), header = true, highlight = current == Tier.GUEST)
                    Cell("Superior", Modifier.weight(1f), header = true, highlight = current == Tier.SUPERIOR)
                    Cell("Premium", Modifier.weight(1f), header = true, highlight = current == Tier.PREMIUM)
                }
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                rows.forEach { r ->
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Cell(r.feature, Modifier.weight(1.4f), label = true)
                        Cell(r.guest, Modifier.weight(1f), highlight = current == Tier.GUEST)
                        Cell(r.superior, Modifier.weight(1f), highlight = current == Tier.SUPERIOR)
                        Cell(r.premium, Modifier.weight(1f), highlight = current == Tier.PREMIUM)
                    }
                }
                Text(
                    "New accounts get Superior free for the first 30 days.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 10.dp)
                )
                onSubscribe?.let { subscribe ->
                    Column(
                        modifier = Modifier.padding(top = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (current != Tier.PREMIUM) {
                            Button(
                                onClick = { subscribe(Plans.PREMIUM) },
                                enabled = !busy,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(46.dp),
                                shape = RoundedCornerShape(12.dp)
                            ) { Text("Go Premium · ${Plans.PREMIUM_PRICE}", fontWeight = FontWeight.SemiBold) }
                        }
                        if (current == Tier.GUEST) {
                            OutlinedButton(
                                onClick = { subscribe(Plans.SUPERIOR) },
                                enabled = !busy,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(46.dp),
                                shape = RoundedCornerShape(12.dp)
                            ) { Text("Superior · ${Plans.SUPERIOR_PRICE}") }
                        }
                    }
                }
            }
        },
        confirmButton = {
            onSignIn?.let {
                Button(onClick = it, enabled = !busy) { Text("Continue with Google") }
            } ?: TextButton(onClick = onDismiss) { Text("Close") }
        },
        dismissButton = {
            if (onSignIn != null) TextButton(onClick = onDismiss) { Text("Not now") }
        }
    )
}

@Composable
private fun Cell(text: String, modifier: Modifier, header: Boolean = false, label: Boolean = false, highlight: Boolean = false) {
    Text(
        text,
        style = if (header) MaterialTheme.typography.labelMedium else MaterialTheme.typography.bodySmall,
        fontWeight = if (header || label) FontWeight.SemiBold else FontWeight.Normal,
        textAlign = if (label) TextAlign.Start else TextAlign.Center,
        color = when {
            highlight -> MaterialTheme.colorScheme.primary
            label -> MaterialTheme.colorScheme.onSurface
            else -> MaterialTheme.colorScheme.onSurfaceVariant
        },
        modifier = modifier
            .then(if (highlight) Modifier.background(MaterialTheme.colorScheme.primary.copy(alpha = 0.08f)) else Modifier)
            .padding(vertical = 5.dp, horizontal = 2.dp)
    )
}
