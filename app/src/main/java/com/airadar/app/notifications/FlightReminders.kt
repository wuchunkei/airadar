package com.airadar.app.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.airadar.app.MainActivity
import com.airadar.app.data.BackendClient
import com.airadar.app.data.Flight
import com.airadar.app.data.FlightStatus
import java.io.IOException
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit

/**
 * The on-device half of the reminder schedule. Every stage is a one-shot
 * WorkManager job keyed by flight id, so adding a flight twice or removing it
 * replaces or clears the whole set. Stages that depend on noticing a change
 * (a new delay, an early departure) are the backend's job and arrive as pushes.
 */
object FlightReminders {

    private const val CHANNEL_SCHEDULE = "flight_schedule"
    private const val CHANNEL_LIVE = "flight_live"
    private const val CHANNEL_INFLIGHT = "flight_inflight"

    enum class Stage { SCHEDULED, STATUS, INFLIGHT, LANDED }

    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_SCHEDULE, "Trip reminders", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "The day before, and three hours before departure" }
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_LIVE, "Live updates", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Delays, gate changes, departure and landing" }
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_INFLIGHT, "In flight", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Progress while airborne" }
        )
    }

    /** (Re)schedules every stage for [flight]; earlier work for the same flight is replaced. */
    fun schedule(context: Context, flight: Flight) {
        val departure = flight.departureInstant ?: return
        val arrival = flight.arrivalInstant ?: return
        val now = Instant.now()
        val work = WorkManager.getInstance(context)

        fun enqueue(stage: Stage, at: Instant) {
            val delay = Duration.between(now, at)
            if (delay.isNegative) return
            val request = OneTimeWorkRequestBuilder<ReminderWorker>()
                .setInitialDelay(delay.toMillis(), TimeUnit.MILLISECONDS)
                .setInputData(flight.toData(stage))
                .build()
            work.enqueueUniqueWork(workName(flight.id, stage), ExistingWorkPolicy.REPLACE, request)
        }

        enqueue(Stage.SCHEDULED, departure.minus(Duration.ofHours(16)))
        enqueue(Stage.STATUS, departure.minus(Duration.ofHours(3)))
        enqueue(Stage.INFLIGHT, departure)
        enqueue(Stage.LANDED, arrival.plus(Duration.ofHours(1)))
    }

    fun cancel(context: Context, flightId: String) {
        val work = WorkManager.getInstance(context)
        Stage.entries.forEach { work.cancelUniqueWork(workName(flightId, it)) }
        NotificationManagerCompat.from(context).cancel(flightId.hashCode())
    }

    private fun workName(flightId: String, stage: Stage) = "reminder:$flightId:${stage.name}"

    // ---- worker --------------------------------------------------------------

    class ReminderWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

        override suspend fun doWork(): Result {
            val stage = Stage.valueOf(inputData.getString(KEY_STAGE) ?: return Result.failure())
            val number = inputData.getString(KEY_NUMBER) ?: return Result.failure()
            val date = LocalDate.parse(inputData.getString(KEY_DATE) ?: return Result.failure())
            val route = inputData.getString(KEY_ROUTE).orEmpty()
            val depAt = LocalDateTime.parse(inputData.getString(KEY_DEP) ?: return Result.failure())
            val arrAt = LocalDateTime.parse(inputData.getString(KEY_ARR) ?: return Result.failure())
            val terminal = inputData.getString(KEY_TERMINAL)
            val id = inputData.getString(KEY_ID) ?: return Result.failure()

            ensureChannels(applicationContext)

            when (stage) {
                Stage.SCHEDULED -> post(
                    id, CHANNEL_SCHEDULE,
                    title = "$number tomorrow · $route",
                    text = "Departs ${depAt.format(clock)}" + (terminal?.let { " from Terminal $it" } ?: "")
                )

                Stage.STATUS -> {
                    val live = fetch(number, date)
                    post(
                        id, CHANNEL_SCHEDULE,
                        title = "$number in 3 hours · $route",
                        text = live?.let { statusLine(it) } ?: "Scheduled ${depAt.format(clock)} · status unavailable"
                    )
                }

                Stage.INFLIGHT -> {
                    val now = LocalDateTime.now()
                    if (now.isAfter(arrAt)) {
                        NotificationManagerCompat.from(applicationContext).cancel(id.hashCode())
                        return Result.success()
                    }
                    val total = Duration.between(depAt, arrAt).toMinutes().coerceAtLeast(1)
                    val elapsed = Duration.between(depAt, now).toMinutes().coerceIn(0, total)
                    val remaining = total - elapsed
                    post(
                        id, CHANNEL_INFLIGHT,
                        title = "$number · $route",
                        text = "Landing in ${formatMinutes(remaining)} · ${arrAt.format(clock)}",
                        ongoing = true,
                        progress = (elapsed * 100 / total).toInt()
                    )
                    // Refresh the bar until arrival; 15 min is WorkManager's floor.
                    WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                        workName(id, Stage.INFLIGHT),
                        ExistingWorkPolicy.REPLACE,
                        OneTimeWorkRequestBuilder<ReminderWorker>()
                            .setInitialDelay(15, TimeUnit.MINUTES)
                            .setInputData(inputData)
                            .build()
                    )
                }

                Stage.LANDED -> {
                    NotificationManagerCompat.from(applicationContext).cancel(id.hashCode())
                    val live = fetch(number, date)
                    val landedAt = live?.takeIf { it.status == FlightStatus.LANDED }
                        ?.arrivalTime?.plusMinutes(live.delayMinutes.toLong())
                    post(
                        id, CHANNEL_LIVE,
                        title = "$number · landed",
                        text = landedAt?.let { "Arrived ${it.format(clock)}" + lateSuffix(live.delayMinutes) }
                            ?: "Scheduled arrival ${arrAt.format(clock)} · actual time unavailable"
                    )
                }
            }
            return Result.success()
        }

        private suspend fun fetch(number: String, date: LocalDate): Flight? =
            try {
                if (BackendClient.isConfigured) BackendClient.flight(number, date) else null
            } catch (_: IOException) {
                null
            }

        private fun statusLine(flight: Flight): String {
            val gate = flight.departureGate?.let { " · Gate $it" } ?: ""
            val terminal = flight.departureTerminal?.let { " · T$it" } ?: ""
            val dep = flight.departureTime.plusMinutes(flight.delayMinutes.toLong()).format(clock)
            return when (flight.status) {
                FlightStatus.CANCELLED -> "Cancelled"
                FlightStatus.DELAYED -> "Delayed to $dep (+${flight.delayMinutes} min)$terminal$gate"
                else -> "On time · $dep$terminal$gate"
            }
        }

        private fun lateSuffix(delay: Int) = if (delay > 0) " · $delay min late" else " · on time"

        private fun post(
            id: String,
            channel: String,
            title: String,
            text: String,
            ongoing: Boolean = false,
            progress: Int? = null
        ) {
            val context = applicationContext
            val allowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
            if (!allowed) return

            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val builder = NotificationCompat.Builder(context, channel)
                .setSmallIcon(android.R.drawable.ic_menu_compass)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setOngoing(ongoing)
                .setOnlyAlertOnce(ongoing)
                .setAutoCancel(!ongoing)
            if (progress != null) builder.setProgress(100, progress, false)
            NotificationManagerCompat.from(context).notify(id.hashCode(), builder.build())
        }
    }

    // ---- data plumbing ---------------------------------------------------------

    private const val KEY_ID = "id"
    private const val KEY_STAGE = "stage"
    private const val KEY_NUMBER = "number"
    private const val KEY_DATE = "date"
    private const val KEY_ROUTE = "route"
    private const val KEY_DEP = "dep"
    private const val KEY_ARR = "arr"
    private const val KEY_TERMINAL = "terminal"

    // Everything the worker needs rides in its input: the in-memory store may be
    // gone by the time a job fires hours later.
    private fun Flight.toData(stage: Stage): Data = workDataOf(
        KEY_ID to id,
        KEY_STAGE to stage.name,
        KEY_NUMBER to flightNumber,
        KEY_DATE to departureTime.toLocalDate().toString(),
        KEY_ROUTE to "$departure → $arrival",
        KEY_DEP to departureTime.toString(),
        KEY_ARR to arrivalTime.toString(),
        KEY_TERMINAL to departureTerminal
    )

    private val clock: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")

    private fun formatMinutes(minutes: Long): String {
        val h = minutes / 60
        val m = minutes % 60
        return when {
            h == 0L -> "${m} min"
            m == 0L -> "${h} h"
            else -> "${h} h ${m} min"
        }
    }
}
