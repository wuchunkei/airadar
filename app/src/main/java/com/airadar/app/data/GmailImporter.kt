package com.airadar.app.data

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Reads the traveller's Gmail through the Gmail REST API with an access token
 * the phone obtained itself (gmail.readonly, granted on Google's own consent
 * screen). Nothing is stored: mail is fetched, scanned for flight numbers and
 * dates, and forgotten.
 */
object GmailImporter {

    const val SCOPE = "https://www.googleapis.com/auth/gmail.readonly"

    private const val BASE = "https://gmail.googleapis.com/gmail/v1/users/me"

    /**
     * Every mail from the last two years that mentions a flight in any of the
     * languages a booking might arrive in. Reading literally every message
     * would mean thousands of downloads; this catches anything with a flight
     * in it and finishes in seconds.
     */
    private const val QUERY =
        "newer_than:2y (flight OR itinerary OR booking OR e-ticket OR boarding OR " +
                "reservation OR 航班 OR 行程 OR 机票 OR 機票 OR 登机 OR 登機 OR 預訂 OR 预订)"

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    class Progress(val scanned: Int, val total: Int)

    /** Scans the mailbox and returns every flight/date pair found, most recent mail first. */
    suspend fun scan(accessToken: String, onProgress: (Progress) -> Unit): List<Candidate> =
        withContext(Dispatchers.IO) {
            val ids = mutableListOf<String>()
            var pageToken: String? = null
            do {
                val page = get(accessToken, "messages", "q" to QUERY, "maxResults" to "100", "pageToken" to pageToken)
                page.optJSONArray("messages")?.let { arr ->
                    for (i in 0 until arr.length()) ids += arr.getJSONObject(i).getString("id")
                }
                pageToken = page.optString("nextPageToken").ifBlank { null }
            } while (pageToken != null && ids.size < 1000)

            val found = mutableListOf<Candidate>()
            ids.forEachIndexed { index, id ->
                val message = get(accessToken, "messages/$id", "format" to "full")
                val text = buildString {
                    appendLine(message.optString("snippet"))
                    message.optJSONObject("payload")?.let { collectText(it, this) }
                }
                found += FlightEmailParser.candidates(text)
                onProgress(Progress(index + 1, ids.size))
            }
            found.distinct()
        }

    /** Walks the MIME tree; text/plain parts as they are, HTML with its tags stripped. */
    private fun collectText(part: JSONObject, into: StringBuilder) {
        val mime = part.optString("mimeType")
        val data = part.optJSONObject("body")?.optString("data").orEmpty()
        if (data.isNotEmpty() && (mime.startsWith("text/plain") || mime.startsWith("text/html"))) {
            val raw = String(Base64.decode(data, Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8)
            into.appendLine(if (mime.startsWith("text/html")) stripHtml(raw) else raw)
        }
        part.optJSONArray("parts")?.let { parts ->
            for (i in 0 until parts.length()) collectText(parts.getJSONObject(i), into)
        }
    }

    private fun stripHtml(html: String): String =
        html.replace(Regex("<(script|style)[^>]*>.*?</\\1>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)), " ")
            .replace(Regex("<br\\s*/?>|</p>|</div>|</tr>|</li>", RegexOption.IGNORE_CASE), "\n")
            .replace(Regex("<[^>]+>"), " ")
            .replace("&nbsp;", " ").replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
            .replace(Regex("[ \\t]+"), " ")

    private fun get(token: String, path: String, vararg query: Pair<String, String?>): JSONObject {
        val url = "$BASE/$path".toHttpUrl().newBuilder()
            .apply { query.forEach { (k, v) -> if (v != null) addQueryParameter(k, v) } }
            .build()
        val request = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        val (code, body) = http.newCall(request).execute().use { it.code to it.body?.string().orEmpty() }
        if (code == 401 || code == 403) throw IOException("Gmail access was refused (HTTP $code). Grant access again.")
        if (code !in 200..299) throw IOException("Gmail returned HTTP $code.")
        return JSONObject(body)
    }
}
