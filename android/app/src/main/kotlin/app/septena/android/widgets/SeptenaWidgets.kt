package app.septena.android.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import app.septena.android.MainActivity
import app.septena.android.R
import app.septena.android.SeptenaAndroidApp
import app.septena.core.generated.RegistryDestinationIds
import app.septena.transport.SeptenaShareClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Deep-link action delivered from a home-screen widget into [MainActivity]. */
sealed interface WidgetLaunchAction {
    data class OpenDestination(val destinationId: String) : WidgetLaunchAction
    data class OpenTask(val taskId: String, val destinationId: String?) : WidgetLaunchAction
    data class QuickAdd(val today: Boolean) : WidgetLaunchAction

    /** An invite link (`septask://join/<token>`): asks before it joins. */
    data class JoinShare(val token: String) : WidgetLaunchAction
}

object SeptenaWidgetIntents {
    const val ACTION_COMPLETE_TASK = "app.septena.android.widgets.ACTION_COMPLETE_TASK"
    const val EXTRA_TASK_ID = "app.septena.android.widgets.EXTRA_TASK_ID"
    const val EXTRA_DESTINATION_ID = "app.septena.android.widgets.EXTRA_DESTINATION_ID"
    const val EXTRA_QUICK_ADD_TODAY = "app.septena.android.widgets.EXTRA_QUICK_ADD_TODAY"

    fun parseLaunchAction(intent: Intent?): WidgetLaunchAction? {
        if (intent == null) return null
        intent.dataString?.let(SeptenaShareClient::inviteToken)?.let { return WidgetLaunchAction.JoinShare(it) }
        val taskId = intent.getStringExtra(EXTRA_TASK_ID)
        val destId = intent.getStringExtra(EXTRA_DESTINATION_ID)
        if (!taskId.isNullOrBlank()) {
            return WidgetLaunchAction.OpenTask(taskId, destId)
        }
        if (intent.hasExtra(EXTRA_QUICK_ADD_TODAY)) {
            return WidgetLaunchAction.QuickAdd(intent.getBooleanExtra(EXTRA_QUICK_ADD_TODAY, true))
        }
        if (!destId.isNullOrBlank()) {
            return WidgetLaunchAction.OpenDestination(destId)
        }
        return null
    }
}

class TodayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val pending = goAsync()
        widgetScope.launch {
            try {
                SeptenaWidgetUpdater.updateToday(context, appWidgetManager, appWidgetIds)
            } finally {
                pending.finish()
            }
        }
    }
}

class UpcomingWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val pending = goAsync()
        widgetScope.launch {
            try {
                SeptenaWidgetUpdater.updateUpcoming(context, appWidgetManager, appWidgetIds)
            } finally {
                pending.finish()
            }
        }
    }
}

class SeptenaWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != SeptenaWidgetIntents.ACTION_COMPLETE_TASK) return
        val taskId = intent.getStringExtra(SeptenaWidgetIntents.EXTRA_TASK_ID) ?: return
        val pending = goAsync()
        widgetScope.launch {
            try {
                val app = context.applicationContext as? SeptenaAndroidApp ?: return@launch
                app.graph.taskMutator.complete(taskId)
                app.graph.sync.noteLocalChange()
                app.graph.sync.requestSync()
                SeptenaWidgetUpdater.refreshAll(context)
            } finally {
                pending.finish()
            }
        }
    }
}

object SeptenaWidgetUpdater {
    suspend fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val todayIds = manager.getAppWidgetIds(ComponentName(context, TodayWidgetProvider::class.java))
        if (todayIds.isNotEmpty()) {
            updateToday(context, manager, todayIds)
        }
        val upcomingIds = manager.getAppWidgetIds(ComponentName(context, UpcomingWidgetProvider::class.java))
        if (upcomingIds.isNotEmpty()) {
            updateUpcoming(context, manager, upcomingIds)
        }
    }

    internal suspend fun updateToday(context: Context, manager: AppWidgetManager, ids: IntArray) {
        if (ids.isEmpty()) return
        val app = context.applicationContext as? SeptenaAndroidApp ?: return
        val languageTag = context.resources.configuration.locales[0].toLanguageTag()
        val snapshot = SeptenaWidgetLoader.loadToday(app.graph.taskStore, app.graph.clock, languageTag)
        val views = buildRemoteViews(
            context = context,
            snapshot = snapshot,
            iconRes = R.drawable.ic_widget_sun,
            quickAddToday = true,
            requestSalt = 1000,
        )
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    internal suspend fun updateUpcoming(context: Context, manager: AppWidgetManager, ids: IntArray) {
        if (ids.isEmpty()) return
        val app = context.applicationContext as? SeptenaAndroidApp ?: return
        val languageTag = context.resources.configuration.locales[0].toLanguageTag()
        val snapshot = SeptenaWidgetLoader.loadUpcoming(app.graph.taskStore, app.graph.clock, languageTag)
        val views = buildRemoteViews(
            context = context,
            snapshot = snapshot,
            iconRes = R.drawable.ic_widget_calendar,
            quickAddToday = false,
            requestSalt = 2000,
        )
        ids.forEach { manager.updateAppWidget(it, views) }
    }

    private fun buildRemoteViews(
        context: Context,
        snapshot: WidgetSnapshot,
        iconRes: Int,
        quickAddToday: Boolean,
        requestSalt: Int,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_task_list)
        views.setImageViewResource(R.id.widget_header_icon, iconRes)
        views.setTextViewText(R.id.widget_header_title, snapshot.title)
        if (snapshot.totalCount > 0) {
            views.setViewVisibility(R.id.widget_header_count, View.VISIBLE)
            views.setTextViewText(R.id.widget_header_count, snapshot.totalCount.toString())
        } else {
            views.setViewVisibility(R.id.widget_header_count, View.GONE)
        }

        val openListIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(SeptenaWidgetIntents.EXTRA_DESTINATION_ID, snapshot.destinationId)
        }
        val openListPending = PendingIntent.getActivity(
            context,
            requestSalt + 1,
            openListIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_header, openListPending)

        val quickAddIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(SeptenaWidgetIntents.EXTRA_QUICK_ADD_TODAY, quickAddToday)
            putExtra(SeptenaWidgetIntents.EXTRA_DESTINATION_ID, snapshot.destinationId)
        }
        val quickAddPending = PendingIntent.getActivity(
            context,
            requestSalt + 2,
            quickAddIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_add_button, quickAddPending)

        if (snapshot.rows.isEmpty()) {
            views.setViewVisibility(R.id.widget_empty_label, View.VISIBLE)
            views.setTextViewText(R.id.widget_empty_label, snapshot.emptyLabel)
            views.setOnClickPendingIntent(R.id.widget_empty_label, openListPending)
        } else {
            views.setViewVisibility(R.id.widget_empty_label, View.GONE)
        }

        val overdueColor = context.getColor(R.color.widget_overdue_red)
        val secondaryColor = context.getColor(R.color.widget_text_secondary)

        ROW_VIEW_IDS.forEachIndexed { index, ids ->
            val row = snapshot.rows.getOrNull(index)
            if (row == null) {
                views.setViewVisibility(ids.container, View.GONE)
            } else {
                views.setViewVisibility(ids.container, View.VISIBLE)
                views.setTextViewText(ids.title, row.title)
                if (row.trailingMeta != null) {
                    views.setViewVisibility(ids.meta, View.VISIBLE)
                    views.setTextViewText(ids.meta, row.trailingMeta)
                    views.setTextColor(ids.meta, if (row.isRedMeta) overdueColor else secondaryColor)
                } else {
                    views.setViewVisibility(ids.meta, View.GONE)
                }

                val openTaskIntent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(SeptenaWidgetIntents.EXTRA_TASK_ID, row.id)
                    putExtra(SeptenaWidgetIntents.EXTRA_DESTINATION_ID, snapshot.destinationId)
                }
                val openTaskPending = PendingIntent.getActivity(
                    context,
                    requestSalt + 10 + index,
                    openTaskIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(ids.container, openTaskPending)

                val completeIntent = Intent(context, SeptenaWidgetActionReceiver::class.java).apply {
                    action = SeptenaWidgetIntents.ACTION_COMPLETE_TASK
                    putExtra(SeptenaWidgetIntents.EXTRA_TASK_ID, row.id)
                }
                val completePending = PendingIntent.getBroadcast(
                    context,
                    requestSalt + 50 + index,
                    completeIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                views.setOnClickPendingIntent(ids.check, completePending)
            }
        }

        if (snapshot.overflowCount > 0) {
            views.setViewVisibility(R.id.widget_more_label, View.VISIBLE)
            views.setTextViewText(R.id.widget_more_label, "+${snapshot.overflowCount} more")
            views.setOnClickPendingIntent(R.id.widget_more_label, openListPending)
        } else {
            views.setViewVisibility(R.id.widget_more_label, View.GONE)
        }

        return views
    }

    private data class RowIds(val container: Int, val check: Int, val title: Int, val meta: Int)

    private val ROW_VIEW_IDS = listOf(
        RowIds(R.id.widget_row_0, R.id.widget_row_0_check, R.id.widget_row_0_title, R.id.widget_row_0_meta),
        RowIds(R.id.widget_row_1, R.id.widget_row_1_check, R.id.widget_row_1_title, R.id.widget_row_1_meta),
        RowIds(R.id.widget_row_2, R.id.widget_row_2_check, R.id.widget_row_2_title, R.id.widget_row_2_meta),
        RowIds(R.id.widget_row_3, R.id.widget_row_3_check, R.id.widget_row_3_title, R.id.widget_row_3_meta),
        RowIds(R.id.widget_row_4, R.id.widget_row_4_check, R.id.widget_row_4_title, R.id.widget_row_4_meta),
        RowIds(R.id.widget_row_5, R.id.widget_row_5_check, R.id.widget_row_5_title, R.id.widget_row_5_meta),
    )
}

private val widgetScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
