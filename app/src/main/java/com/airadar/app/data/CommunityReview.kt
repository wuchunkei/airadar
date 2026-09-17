package com.airadar.app.data

import java.time.LocalDateTime
import org.json.JSONObject

/**
 * A fed flight the automated scorer (backend/app/feed.py) couldn't settle
 * either way, waiting for other travellers to vote real/not-real on --
 * mirrors community.py's own ReviewOut wire shape exactly.
 */
data class CommunityReview(
    val id: String,
    val flightNumber: String,
    val airlineName: String,
    val departure: String,
    val arrival: String,
    val departureTime: LocalDateTime,
    val arrivalTime: LocalDateTime,
    /** "pending" / "confirmed" / "rejected" / "expired". */
    val status: String,
    val approveCount: Int,
    val rejectCount: Int,
    /** Escalated past its first vote target without reaching 70% -- boosted
     * to the front of the queue for more votes, deadline unchanged. */
    val boosted: Boolean,
    /** null in the open queue (nothing cast yet, by definition); how I
     * voted, in History's "My Reviews". */
    val myVote: Boolean? = null
) {
    val departureAirport: Airport? get() = FlightDatabase.airport(departure)
    val arrivalAirport: Airport? get() = FlightDatabase.airport(arrival)
}

fun communityReviewFromJson(o: JSONObject): CommunityReview = CommunityReview(
    id = o.getString("id"),
    flightNumber = o.optString("flightNumber"),
    airlineName = o.optString("airlineName"),
    departure = o.getString("departure"),
    arrival = o.getString("arrival"),
    departureTime = LocalDateTime.parse(o.getString("departureTime").take(19)),
    arrivalTime = LocalDateTime.parse(o.getString("arrivalTime").take(19)),
    status = o.optString("status"),
    approveCount = o.optInt("approveCount"),
    rejectCount = o.optInt("rejectCount"),
    boosted = o.optBoolean("boosted", false),
    myVote = if (o.has("myVote") && !o.isNull("myVote")) o.getBoolean("myVote") else null
)
