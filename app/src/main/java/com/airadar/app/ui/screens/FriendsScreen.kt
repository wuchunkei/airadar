package com.airadar.app.ui.screens

import com.airadar.app.data.tr

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.airadar.app.data.BackendClient
import com.airadar.app.data.Friend
import com.airadar.app.data.FriendStatus
import com.airadar.app.data.Person
import kotlinx.coroutines.launch
import java.io.IOException

/**
 * Friends: requests waiting on me, the people I share with, requests I sent.
 * New friends are found by email — only travellers who chose to be findable.
 */
@Composable
fun FriendsScreen(
    onBack: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scope = rememberCoroutineScope()
    var friends by remember { mutableStateOf<List<Friend>>(emptyList()) }
    var email by remember { mutableStateOf("") }
    var found by remember { mutableStateOf<Person?>(null) }
    var message by remember { mutableStateOf<String?>(null) }

    val reload: () -> Unit = {
        scope.launch {
            runCatching { BackendClient.friends() }
                .onSuccess { friends = it }
                .onFailure { message = it.message }
        }
    }
    LaunchedEffect(Unit) { reload() }

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
            Text(tr("Friends"), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        }

        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = email,
                        onValueChange = {
                            email = it
                            found = null
                            message = null
                        },
                        label = { Text(tr("Find by email")) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.weight(1f)
                    )
                    Button(
                        onClick = {
                            scope.launch {
                                try {
                                    found = BackendClient.lookup(email)
                                    message = null
                                } catch (e: IOException) {
                                    found = null
                                    message = e.message
                                }
                            }
                        },
                        enabled = email.contains("@"),
                        modifier = Modifier.padding(start = 8.dp),
                        shape = RoundedCornerShape(12.dp)
                    ) { Text(tr("Find")) }
                }
            }

            found?.let { person ->
                item {
                    PersonRow(person, trailing = {
                        Button(
                            onClick = {
                                scope.launch {
                                    runCatching { BackendClient.requestFriend(person.id) }
                                        .onSuccess {
                                            found = null
                                            email = ""
                                            reload()
                                        }
                                        .onFailure { message = it.message }
                                }
                            },
                            shape = RoundedCornerShape(10.dp)
                        ) { Text(tr("Add friend")) }
                    })
                }
            }

            message?.let {
                item {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }

            val incoming = friends.filter { it.status == FriendStatus.INCOMING }
            val accepted = friends.filter { it.status == FriendStatus.ACCEPTED }
            val outgoing = friends.filter { it.status == FriendStatus.OUTGOING }

            if (incoming.isNotEmpty()) {
                item { Heading(tr("Requests")) }
                items(incoming, key = { it.friendshipId }) { f ->
                    PersonRow(f.person, trailing = {
                        TextButton(onClick = {
                            scope.launch { runCatching { BackendClient.removeFriend(f.friendshipId) }; reload() }
                        }) { Text(tr("Decline")) }
                        Button(
                            onClick = { scope.launch { runCatching { BackendClient.acceptFriend(f.friendshipId) }; reload() } },
                            shape = RoundedCornerShape(10.dp)
                        ) { Text(tr("Accept")) }
                    })
                }
            }

            item { Heading(tr("Friends")) }
            if (accepted.isEmpty()) {
                item {
                    Text(
                        "No friends yet. Find someone by email, or accept a request from a shared trip.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            items(accepted, key = { it.friendshipId }) { f ->
                PersonRow(f.person, trailing = {
                    TextButton(onClick = {
                        scope.launch { runCatching { BackendClient.removeFriend(f.friendshipId) }; reload() }
                    }) { Text(tr("Remove")) }
                })
            }

            if (outgoing.isNotEmpty()) {
                item { Heading(tr("Sent")) }
                items(outgoing, key = { it.friendshipId }) { f ->
                    PersonRow(f.person, trailing = {
                        TextButton(onClick = {
                            scope.launch { runCatching { BackendClient.removeFriend(f.friendshipId) }; reload() }
                        }) { Text(tr("Cancel")) }
                    })
                }
            }
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(top = 8.dp)
    )
}

@Composable
fun PersonRow(person: Person, trailing: @Composable () -> Unit) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .background(person.tint, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    person.givenName.take(1).uppercase(),
                    color = androidx.compose.ui.graphics.Color.White,
                    fontWeight = FontWeight.Bold
                )
            }
            Text(
                person.givenName,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = person.tint,
                modifier = Modifier
                    .weight(1f)
                    .padding(start = 12.dp)
            )
            trailing()
        }
    }
}
