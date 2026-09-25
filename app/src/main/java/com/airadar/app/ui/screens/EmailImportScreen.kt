package com.airadar.app.ui.screens

import com.airadar.app.data.tr

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.airadar.app.data.FlightEmailParser
import com.airadar.app.data.GmailImporter
import com.airadar.app.data.TripImporter
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.launch

private sealed interface Scan {
    data object Idle : Scan
    data class Reading(val done: Int, val total: Int) : Scan
    data class Resolving(val done: Int, val total: Int) : Scan
    data class Done(val mails: Int, val added: Int) : Scan
    data class Failed(val reason: String) : Scan
}

/**
 * Trips out of Gmail: Google's own consent sheet grants read access once, the
 * mailbox is searched for anything that mentions a flight, and every flight
 * number found is checked against the timetable and added as a pending trip.
 */
@Composable
fun EmailImportScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var scan by remember { mutableStateOf<Scan>(Scan.Idle) }

    // Runs once Gmail access is in hand.
    val readMailbox: (String) -> Unit = { token ->
        scope.launch {
            try {
                scan = Scan.Reading(0, 0)
                val found = GmailImporter.scan(token) { scan = Scan.Reading(it.scanned, it.total) }
                scan = Scan.Resolving(0, found.size)
                val added = TripImporter.import(found) { done, total -> scan = Scan.Resolving(done, total) }
                scan = Scan.Done((scan as? Scan.Resolving)?.total ?: found.size, added)
            } catch (e: Exception) {
                scan = Scan.Failed(e.message ?: tr("Could not read the mailbox."))
            }
        }
    }

    // Google may need to show its consent screen before handing over a token.
    val consent = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val token = runCatching {
                Identity.getAuthorizationClient(context).getAuthorizationResultFromIntent(result.data!!).accessToken
            }.getOrNull()
            if (token != null) readMailbox(token) else scan = Scan.Failed(tr("Google did not return access."))
        } else {
            scan = Scan.Idle
        }
    }

    val connect: () -> Unit = {
        scan = Scan.Reading(0, 0)
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope(GmailImporter.SCOPE)))
            .build()
        Identity.getAuthorizationClient(context).authorize(request)
            .addOnSuccessListener { result ->
                val token = result.accessToken
                when {
                    result.hasResolution() -> result.pendingIntent?.let {
                        consent.launch(IntentSenderRequest.Builder(it.intentSender).build())
                    }
                    token != null -> readMailbox(token)
                    else -> scan = Scan.Failed(tr("Google did not return access."))
                }
            }
            .addOnFailureListener { scan = Scan.Failed(it.message ?: tr("Google sign-in is unavailable.")) }
    }

    var pasted by remember { mutableStateOf("") }
    var pastedResult by remember { mutableStateOf<Int?>(null) }

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
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = tr("Back"))
            }
            Text(
                tr("Import from email"),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
        }

        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            val busy = scan is Scan.Reading || scan is Scan.Resolving
            Button(
                onClick = connect,
                enabled = !busy,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                if (busy) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary
                    )
                } else {
                    Text(tr("Read my Gmail"), fontWeight = FontWeight.SemiBold)
                }
            }

            when (val s = scan) {
                Scan.Idle -> Unit
                is Scan.Reading -> Progress(
                    if (s.total == 0) tr("Searching the mailbox") else tr("Reading mail %1\$d of %2\$d", s.done, s.total),
                    s.done, s.total
                )
                is Scan.Resolving -> Progress(tr("Checking flight %1\$d of %2\$d", s.done, s.total), s.done, s.total)
                is Scan.Done -> Text(
                    when {
                        s.mails == 0 -> tr("No mail mentioning a flight in the last two years.")
                        s.added == 0 -> tr("Read %d candidates; every flight is already in Trips.", s.mails)
                        else -> tr("%d trips added — open each one in Trips to confirm.", s.added)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary
                )
                is Scan.Failed -> Text(
                    s.reason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            HorizontalDivider()

            OutlinedTextField(
                value = pasted,
                onValueChange = {
                    pasted = it
                    pastedResult = null
                },
                label = { Text(tr("Or paste a booking confirmation")) },
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 140.dp)
            )

            OutlinedButton(
                onClick = {
                    scope.launch {
                        pastedResult = TripImporter.import(FlightEmailParser.candidates(pasted))
                    }
                },
                enabled = pasted.isNotBlank(),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text(tr("Scan the text"), fontWeight = FontWeight.SemiBold)
            }

            pastedResult?.let { n ->
                Text(
                    if (n == 0) tr("No new flights recognised.") else tr("%d trips added — confirm them in Trips.", n),
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (n == 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
                )
            }
        }
    }
}

@Composable
private fun Progress(label: String, done: Int, total: Int) {
    Column {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (total > 0) {
            LinearProgressIndicator(
                progress = { done.toFloat() / total },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
            )
        } else {
            LinearProgressIndicator(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 8.dp)
            )
        }
    }
}
