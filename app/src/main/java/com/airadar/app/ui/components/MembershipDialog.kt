package com.airadar.app.ui.components

import com.airadar.app.data.tr

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.airadar.app.data.Plans
import com.airadar.app.data.Tier

private class PlanRow(val feature: String, val guest: String, val premium: String)

private val rows = listOf(
    PlanRow("Trips ahead", "1 at a time", "Unlimited"),
    PlanRow("Past trips", "Last 7 days", "Unlimited"),
    PlanRow("Add ahead", "Any date", "Any date"),
    PlanRow("Cloud sync", "Last 7 days", "Unlimited"),
    PlanRow("Reminders & tiers", "✓", "✓"),
    PlanRow("Search a flight", "✓", "✓"),
    PlanRow("Recycle bin", "—", "✓"),
    PlanRow("Flown tracks", "—", "✓"),
    PlanRow("Gmail & calendar import", "—", "✓"),
    PlanRow("Price", "Free", Plans.PREMIUM_PRICE)
)

/**
 * Guest / Premium side by side, plus the separate Share add-on. Shown before
 * sign-in (with the Google button), from Settings (with subscribe buttons),
 * and whenever a plan limit is hit (with the reason on top).
 */
@Composable
fun MembershipDialog(
    current: Tier,
    canShare: Boolean = false,
    reason: String? = null,
    onDismiss: () -> Unit,
    /** Opens the web page to buy a plan. */
    onGetPlan: () -> Unit,
    /** Goes to Settings › Account to enter the token. */
    onEnterToken: () -> Unit
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
                    Cell(tr("Premium"), Modifier.weight(1f), header = true, highlight = current == Tier.PREMIUM)
                }
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                rows.forEach { r ->
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Cell(r.feature, Modifier.weight(1.4f), label = true)
                        Cell(r.guest, Modifier.weight(1f), highlight = current == Tier.GUEST)
                        Cell(r.premium, Modifier.weight(1f), highlight = current == Tier.PREMIUM)
                    }
                }
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                // Not a tier column -- its own small subscription, held or
                // not regardless of Guest/Premium.
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(tr("Share"), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Send trips to friends — ${Plans.SHARE_PRICE}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Icon(
                        if (canShare) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                        contentDescription = null,
                        tint = if (canShare) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Text(
                    "Premium is bought on the web (monthly, or once as a lifetime buyout) and unlocked in the app with a token; a subscription keeps working for 3 days after a period ends.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 10.dp)
                )
                Column(
                    modifier = Modifier.padding(top = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = onGetPlan,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(46.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) { Text("Get a plan on the web", fontWeight = FontWeight.SemiBold) }
                    OutlinedButton(
                        onClick = onEnterToken,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(46.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) { Text("I have a token") }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(tr("Close")) } }
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
