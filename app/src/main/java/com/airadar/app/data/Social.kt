package com.airadar.app.data

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance

/** Another traveller, as far as anyone else needs to know them. */
@Immutable
data class Person(val id: String, val givenName: String, val color: String) {
    val tint: Color get() = colorOf(color)
}

enum class ShareStatus { PENDING, ACCEPTED, REJECTED, TOGETHER }

/** One share of one trip: the other party and where they stand on it. */
@Immutable
data class TripShare(val id: String, val person: Person, val status: ShareStatus)

enum class FriendStatus { ACCEPTED, INCOMING, OUTGOING }

@Immutable
data class Friend(val friendshipId: String, val person: Person, val status: FriendStatus)

/** The colours a traveller may pick; the server rejects anything else. */
val PersonPalette = listOf(
    "#E53935", "#F4511E", "#FB8C00", "#F9A825", "#7CB342", "#43A047",
    "#00897B", "#00ACC1", "#1E88E5", "#3949AB", "#8E24AA", "#D81B60"
)

fun colorOf(hex: String): Color =
    runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(Color(0xFF1E88E5))

/** Black or white, whichever reads on [background]. */
fun Color.onColor(): Color = if (luminance() > 0.45f) Color(0xFF111111) else Color.White

/** Order for a card's share blocks: the state that matters most first, then by name. */
val ShareStatus.rank: Int
    get() = when (this) {
        ShareStatus.TOGETHER -> 0
        ShareStatus.ACCEPTED -> 1
        ShareStatus.PENDING -> 2
        ShareStatus.REJECTED -> 3
    }

fun List<TripShare>.sortedForDisplay(): List<TripShare> =
    sortedWith(compareBy<TripShare> { it.status.rank }.thenBy { it.person.givenName.lowercase() })
