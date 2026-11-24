package app.septena.android.ui

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.transport.IcalFeed
import kotlinx.coroutines.launch

/**
 * Surface `calendar_detail` on Android: the private iCal feed of dated tasks
 * (`/v1/ical/settings`), like the feed section of iOS `CalendarDetail`. The device
 * calendar part (events in Today and Upcoming) is `calendar.events`, still planned
 * on Android, so this page has no calendar list.
 */
@Composable
internal fun CalendarFeedSection(graph: AndroidAppGraph, signedIn: Boolean, languageTag: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var feed by remember { mutableStateOf<IcalFeed?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmRotate by remember { mutableStateOf(false) }
    fun copy(id: String) = settingsCopy(CALENDAR, id, languageTag)

    LaunchedEffect(signedIn) {
        if (!signedIn) {
            feed = null
            return@LaunchedEffect
        }
        try {
            feed = graph.access.icalFeed()
            error = null
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            error = failure.message ?: failure.toString()
        }
    }

    fun update(enabled: Boolean? = null, scopeValue: String? = null, rotate: Boolean? = null) {
        if (busy) return
        scope.launch {
            busy = true
            try {
                feed = graph.access.updateIcalFeed(enabled = enabled, scope = scopeValue, rotate = rotate)
                error = null
            } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                error = failure.message ?: failure.toString()
            } finally {
                busy = false
            }
        }
    }

    SectionHeader(copy("feedHeader"))
    if (!signedIn) {
        SectionFooter(copy("feedSignIn"))
        return
    }
    val current = feed
    val enabled = current?.enabled == true
    ListItem(
        headlineContent = { Text(copy("feedToggle")) },
        trailingContent = {
            Switch(checked = enabled, onCheckedChange = { update(enabled = it) }, enabled = current != null && !busy)
        },
        modifier = Modifier.fillMaxWidth(),
    )
    if (current != null && enabled) {
        ListItem(headlineContent = { Text(copy("include")) })
        listOf(SCOPE_ALL to copy("scopeAll"), SCOPE_TIMED to copy("scopeTimed")).forEach { (value, title) ->
            ListItem(
                headlineContent = { Text(title) },
                leadingContent = {
                    RadioButton(selected = current.scope == value, onClick = { update(scopeValue = value) }, enabled = !busy)
                },
                modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) { update(scopeValue = value) },
            )
        }
        current.webcalUrl?.let { webcal ->
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                Text(
                    webcal,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = { copyToClipboard(context, copy("feedToggle"), webcal) }, enabled = !busy) {
                        Text(copy("copyUrl"))
                    }
                    TextButton(onClick = {
                        // Android has no webcal:// handler; fall back to Google Calendar's web subscribe URL.
                        if (!openUrl(context, webcal)) openUrl(context, GOOGLE_CALENDAR_SUBSCRIBE + Uri.encode(webcal))
                    }) { Text(copy("openInCalendar")) }
                    TextButton(onClick = { confirmRotate = true }, enabled = !busy) {
                        Text(copy("rotate"), color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
    }
    error?.let {
        Text(
            it,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }
    SectionFooter(copy("feedFooter"))

    if (confirmRotate) {
        AlertDialog(
            onDismissRequest = { confirmRotate = false },
            title = { Text(copy("rotateTitle")) },
            text = { Text(copy("rotateMessage")) },
            confirmButton = {
                TextButton(onClick = {
                    confirmRotate = false
                    update(rotate = true)
                }) { Text(copy("rotate"), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirmRotate = false }) { Text(promptCancelTitle(languageTag)) }
            },
        )
    }
}

internal fun copyToClipboard(context: Context, label: String, text: String) {
    val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}

/** Opens [url] in the app that handles it; false when no app does. */
internal fun openUrl(context: Context, url: String): Boolean {
    val trimmed = url.trim()
    if (trimmed.isEmpty()) return false
    val uri = Uri.parse(
        if ("://" in trimmed || trimmed.startsWith("mailto:", ignoreCase = true)) trimmed else "https://$trimmed",
    )
    if (trimmed.startsWith("mailto:", ignoreCase = true)) {
        try {
            context.startActivity(Intent(Intent.ACTION_SENDTO, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return true
        } catch (_: ActivityNotFoundException) {
            // Fall through to ACTION_VIEW.
        }
    }
    return try {
        context.startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}

private const val CALENDAR = "calendar_detail"
private const val GOOGLE_CALENDAR_SUBSCRIBE = "https://calendar.google.com/calendar/render?cid="
private const val SCOPE_ALL = "all"
private const val SCOPE_TIMED = "timed"
