package app.septena.android.reminders

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import app.septena.android.SeptenaAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant

/** Runs [block] off the main thread and keeps the receiver alive until it ends. */
private fun BroadcastReceiver.runAsync(block: suspend () -> Unit) {
    val pending = goAsync()
    CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
        try {
            runCatching { block() }
        } finally {
            pending.finish()
        }
    }
}

private fun Context.graph() = (applicationContext as SeptenaAndroidApp).graph

private fun Intent.taskId(): String? = getStringExtra(TaskReminderScheduler.EXTRA_TASK_ID)?.takeIf { it.isNotEmpty() }

/** The alarm of one task reminder went off: post its notification. */
class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_FIRE -> {
                val taskId = intent.taskId() ?: return
                runAsync { context.graph().reminders.fire(taskId) }
            }
            // The planned length of the Do on this device ended (docs/DO_SPEC.md §4).
            ACTION_DO_END -> {
                val sessionId = intent.getStringExtra(TaskReminderScheduler.EXTRA_DO_SESSION_ID) ?: return
                runAsync { context.graph().doing.firePlannedEnd(sessionId) }
            }
        }
    }

    companion object {
        const val ACTION_FIRE = "app.septena.android.reminders.FIRE"
        const val ACTION_DO_END = "app.septena.android.reminders.DO_END"
    }
}

/**
 * Notification actions. Each one writes the synced reminder fields (or the
 * task status) through the task mutator, so every device sees it, then asks
 * for a sync. The same writes Apple's notification actions make.
 */
class ReminderActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val taskId = intent.taskId() ?: return
        val action = intent.action ?: return
        runAsync {
            val graph = context.graph()
            val now = Instant.now()
            when (action) {
                ACTION_COMPLETE -> graph.completeTask(taskId)
                ACTION_SNOOZE_15M -> graph.taskMutator.snoozeReminder(taskId, now.plus(Duration.ofMinutes(15)))
                ACTION_SNOOZE_1H -> graph.taskMutator.snoozeReminder(taskId, now.plus(Duration.ofHours(1)))
                ACTION_DISMISS -> graph.taskMutator.dismissReminder(taskId)
                else -> return@runAsync
            }
            graph.reminders.cancelNotification(taskId)
            graph.reminders.reconcile()
            graph.sync.noteLocalChange()
            if (graph.credentials.signedIn.value) graph.sync.requestSync()
        }
    }

    companion object {
        const val ACTION_COMPLETE = "app.septena.android.reminders.COMPLETE"
        const val ACTION_SNOOZE_15M = "app.septena.android.reminders.SNOOZE_15M"
        const val ACTION_SNOOZE_1H = "app.septena.android.reminders.SNOOZE_1H"
        const val ACTION_DISMISS = "app.septena.android.reminders.DISMISS"

        fun intent(context: Context, taskId: String, action: String): PendingIntent = PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, ReminderActionReceiver::class.java)
                .setAction(action)
                .setData(TaskReminderScheduler.taskUri(taskId))
                .putExtra(TaskReminderScheduler.EXTRA_TASK_ID, taskId),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}

/**
 * Alarms do not survive a reboot, an app update or a clock change: arm them
 * again. Also runs when the user allows exact alarms.
 */
class ReminderRearmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> runAsync {
                context.graph().reminders.reconcile()
                context.graph().doing.refresh()
            }
        }
    }
}
