package app.septena.android.reminders

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import app.septena.android.MainActivity
import app.septena.android.R
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskReminderRules
import app.septena.core.TaskStore
import app.septena.core.WireTimestamp
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Local alarms for timed task reminders (docs/TIMED_REMINDERS_SPEC.md), the
 * Android side of Apple's `TaskReminderScheduler`.
 *
 * - The shared core decides whether a task arms (`shouldArmReminder`); no
 *   copy of that rule lives here.
 * - [reconcile] runs after every sync and every local write (the graph
 *   watches `dataVersion`), after boot, after a time zone or clock change and
 *   when the exact-alarm permission changes. It arms the soonest
 *   [MAX_ARMED] future reminders and cancels the rest.
 * - A posted notification goes away when its task is done, deleted,
 *   dismissed or snoozed on another device.
 * - Exact alarms when the system allows them, otherwise an inexact alarm
 *   that can arrive a few minutes late. The task page links to the setting.
 */
class TaskReminderScheduler(
    private val context: Context,
    private val store: TaskStore,
) {
    private val alarms = context.getSystemService(AlarmManager::class.java)
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Mutex()

    /** True when alarms fire on the minute; false means the system may delay them. */
    fun canScheduleExact(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()

    fun notificationsEnabled(): Boolean = notifications.areNotificationsEnabled()

    suspend fun reconcile(now: Instant = Instant.now()) = lock.withLock {
        ensureChannel()
        val active = mutableSetOf<String>()
        val snoozed = mutableSetOf<String>()
        val candidates = mutableListOf<Pair<String, Instant>>()
        for (record in store.records(RegistryEntityNames.TASK)) {
            val fire = armedFireInstant(record) ?: continue
            active += record.id
            if (record.fields[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue() != null) snoozed += record.id
            // Missed alerts never fire after the fact.
            if (fire.isAfter(now)) candidates += record.id to fire
        }
        val desired = candidates.sortedBy { it.second }.take(MAX_ARMED)
        val desiredIds = desired.map { it.first }.toSet()

        val previous = prefs.getStringSet(KEY_ARMED, emptySet()).orEmpty()
        for (taskId in previous - desiredIds) alarms.cancel(alarmIntent(taskId))
        for ((taskId, fire) in desired) arm(alarmIntent(taskId), fire)
        prefs.edit().putStringSet(KEY_ARMED, desiredIds).apply()

        // A banner for a task that no longer arms, or that was snoozed on
        // another device, goes away (Apple does the same).
        for (posted in notifications.activeNotifications) {
            val tag = posted.tag ?: continue
            if (!tag.startsWith(TAG_PREFIX)) continue
            val taskId = tag.removePrefix(TAG_PREFIX)
            val fire = desired.firstOrNull { it.first == taskId }?.second
            if (taskId !in active || (taskId in snoozed && fire != null)) {
                notifications.cancel(tag, NOTIFICATION_ID)
            }
        }
    }

    /** Posts the reminder for [taskId] when it still arms. Called by the alarm. */
    suspend fun fire(taskId: String, now: Instant = Instant.now()) {
        val record = store.record(RegistryEntityNames.TASK, taskId) ?: return
        val fire = armedFireInstant(record) ?: return
        // An alarm left over from an edit that moved the reminder later.
        if (fire.isAfter(now.plusSeconds(60))) {
            reconcile(now)
            return
        }
        if (!notificationsEnabled()) return
        ensureChannel()
        val copy = ReminderCopy.load(context)
        val title = record.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
            .ifBlank { copy.notificationTitle }
        val open = openApp(taskId.hashCode())
        // Android shows at most three action buttons: Complete and the two
        // shortest snoozes. Swiping the banner away dismisses the reminder,
        // as Apple's custom dismiss action does.
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setWhen(fire.toEpochMilli())
            .setShowWhen(true)
            .setContentIntent(open)
            .setDeleteIntent(ReminderActionReceiver.intent(context, taskId, ReminderActionReceiver.ACTION_DISMISS))
            .addAction(action(copy.complete, taskId, ReminderActionReceiver.ACTION_COMPLETE))
            .addAction(action(copy.snooze15m, taskId, ReminderActionReceiver.ACTION_SNOOZE_15M))
            .addAction(action(copy.snooze1h, taskId, ReminderActionReceiver.ACTION_SNOOZE_1H))
            .build()
        notifications.notify(TAG_PREFIX + taskId, NOTIFICATION_ID, notification)
    }

    fun cancelNotification(taskId: String) {
        notifications.cancel(TAG_PREFIX + taskId, NOTIFICATION_ID)
    }

    /** Arms the one alarm of the Do that this device shows (docs/DO_SPEC.md §4). Replaces an earlier one. */
    fun armDoEnd(sessionId: String, at: Instant) {
        notifications.cancel(DO_END_TAG, NOTIFICATION_ID)
        arm(doEndIntent(sessionId), at)
    }

    fun cancelDoEnd() {
        alarms.cancel(doEndIntent(""))
        notifications.cancel(DO_END_TAG, NOTIFICATION_ID)
    }

    fun postDoEnd(title: String, text: String, at: Instant) {
        if (!notificationsEnabled()) return
        ensureChannel()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setWhen(at.toEpochMilli())
            .setShowWhen(true)
            .setContentIntent(openApp(DO_END_TAG.hashCode()))
            .build()
        notifications.notify(DO_END_TAG, NOTIFICATION_ID, notification)
    }

    private fun openApp(requestCode: Int): PendingIntent = PendingIntent.getActivity(
        context,
        requestCode,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun action(title: String, taskId: String, action: String): Notification.Action =
        Notification.Action.Builder(null as Icon?, title, ReminderActionReceiver.intent(context, taskId, action)).build()

    private fun arm(intent: PendingIntent, fire: Instant) {
        val at = fire.toEpochMilli()
        val exact = canScheduleExact() && runCatching {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
        }.isSuccess
        if (!exact) alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, intent)
    }

    private fun alarmIntent(taskId: String): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, ReminderAlarmReceiver::class.java)
            .setAction(ReminderAlarmReceiver.ACTION_FIRE)
            .setData(taskUri(taskId))
            .putExtra(EXTRA_TASK_ID, taskId),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** The same intent for every Do, so a new alarm replaces the last one. */
    private fun doEndIntent(sessionId: String): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        Intent(context, ReminderAlarmReceiver::class.java)
            .setAction(ReminderAlarmReceiver.ACTION_DO_END)
            .putExtra(EXTRA_DO_SESSION_ID, sessionId),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun ensureChannel() {
        if (notifications.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            ReminderCopy.load(context).channel,
            NotificationManager.IMPORTANCE_HIGH,
        )
        notifications.createNotificationChannel(channel)
    }

    companion object {
        /** Headroom like Apple's 50 pending requests; the rest arm as these fire. */
        const val MAX_ARMED = 50
        const val EXTRA_TASK_ID = "app.septena.android.reminders.TASK_ID"
        const val EXTRA_DO_SESSION_ID = "app.septena.android.reminders.DO_SESSION_ID"
        private const val DO_END_TAG = "septena.do.plannedEnd"
        private const val CHANNEL_ID = "septena.task.reminder"
        private const val TAG_PREFIX = "septena.reminder."
        private const val NOTIFICATION_ID = 1
        private const val PREFS = "septena.reminders"
        private const val KEY_ARMED = "armed"

        /** One distinct alarm per task: the data URI keeps the PendingIntents apart. */
        fun taskUri(taskId: String): Uri = Uri.Builder().scheme("septena-reminder").authority("task").appendPath(taskId).build()

        /** When the reminder of [record] fires, or null when the core says it does not arm. */
        fun armedFireInstant(record: SyncRecord, zone: ZoneId = ZoneId.systemDefault()): Instant? {
            val f = record.fields
            val reminderAt = f[RegistryEntityFields.Task.REMINDER_AT].stringValue() ?: return null
            val arms = TaskReminderRules.shouldArm(
                status = f[RegistryEntityFields.Task.STATUS].stringValue().orEmpty(),
                isDeleted = record.deletedAt != null,
                isHeading = f[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING,
                isUnratifiedProposal = f[RegistryEntityFields.Task.SOURCE].stringValue() == RegistryEntityEnums.TaskSource.MCP &&
                    f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue() == null,
                reminderAt = reminderAt,
                reminderDismissedAt = f[RegistryEntityFields.Task.REMINDER_DISMISSED_AT].stringValue(),
            )
            if (!arms) return null
            f[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue()
                ?.let { parseInstant(it) }
                ?.let { return it }
            return ReminderTime.resolve(reminderAt, f[RegistryEntityFields.Task.REMINDER_MODE].stringValue(), zone)
        }

        private fun parseInstant(value: String): Instant? = runCatching { Instant.parse(value) }.getOrNull()
    }
}

/** The wire forms of a reminder time (`reminderAt` + `reminderMode`), as Apple's `TaskReminder.make`. */
object ReminderTime {
    private val floatingFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")

    /**
     * A floating reminder is wall clock `YYYY-MM-DDTHH:MM` and follows the
     * device zone; a fixed one is a UTC instant. A wall time in a DST gap
     * moves forward to the first valid instant.
     */
    fun resolve(reminderAt: String, mode: String?, zone: ZoneId = ZoneId.systemDefault()): Instant? {
        if (mode == RegistryEntityEnums.ReminderMode.FIXED) {
            return runCatching { Instant.parse(reminderAt) }.getOrNull()
        }
        return runCatching { LocalDateTime.parse(reminderAt.take(16), floatingFormat).atZone(zone).toInstant() }
            .getOrNull()
            ?: runCatching { Instant.parse(reminderAt) }.getOrNull()
    }

    /** The `reminderAt` value for [at] in [mode]. */
    fun wireValue(at: LocalDateTime, mode: String, zone: ZoneId = ZoneId.systemDefault()): String =
        if (mode == RegistryEntityEnums.ReminderMode.FIXED) {
            WireTimestamp.format(at.withSecond(0).withNano(0).atZone(zone).toInstant())
        } else {
            floatingFormat.format(at)
        }
}

/** Reminder copy from the registry (surfaces.json `taskDetail.controls`). */
data class ReminderCopy(
    val notificationTitle: String,
    val channel: String,
    val complete: String,
    val snooze15m: String,
    val snooze1h: String,
) {
    companion object {
        fun load(context: Context): ReminderCopy {
            val languageTag = context.resources.configuration.locales[0].toLanguageTag()
            val controls = (RegistryCatalog.surface(RegistryTaskDetail.ID)?.fields?.get("controls") as? JsonValue.ObjectValue)
                ?.fields.orEmpty()
            fun text(id: String): String {
                val raw = controls[id].stringValue().orEmpty()
                return RegistryCatalog.localizedString(raw, languageTag) ?: raw
            }
            return ReminderCopy(
                notificationTitle = text(RegistryTaskDetail.Controls.REMINDER_NOTIFICATION_TITLE),
                channel = text(RegistryTaskDetail.Controls.REMINDER_CHANNEL),
                complete = text(RegistryTaskDetail.Controls.REMINDER_COMPLETE),
                snooze15m = text(RegistryTaskDetail.Controls.REMINDER_SNOOZE15M),
                snooze1h = text(RegistryTaskDetail.Controls.REMINDER_SNOOZE1H),
            )
        }
    }
}
