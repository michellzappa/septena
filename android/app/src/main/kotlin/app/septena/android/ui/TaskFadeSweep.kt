package app.septena.android.ui

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryNoticeIds
import app.septena.core.generated.RegistryRules
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.stringValue
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import java.time.DayOfWeek
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.max

/** One faded task shown in the Weekly Sweep sheet (`docs/TASK_FADE_SPEC.md` §5). */
data class FadeSweepItem(
    val id: String,
    val title: String,
    val reason: String,
    val fadedAt: Instant?,
)

/**
 * Pure date & copy rules mirroring Apple `SeptenaCore/TaskFade.swift`:
 * sweep anchor, sweep due check, and field-derived plain-language reason.
 */
object FadeSweepRules {
    /** Apple `Calendar.weekday` (1 = Sunday..7 = Saturday) mapped to `java.time.DayOfWeek`. */
    fun sweepDayOfWeek(appleWeekday: Int = RegistryRules.FADE_SWEEP_WEEKDAY.toInt()): DayOfWeek = when (appleWeekday) {
        1 -> DayOfWeek.SUNDAY
        2 -> DayOfWeek.MONDAY
        3 -> DayOfWeek.TUESDAY
        4 -> DayOfWeek.WEDNESDAY
        5 -> DayOfWeek.THURSDAY
        6 -> DayOfWeek.FRIDAY
        7 -> DayOfWeek.SATURDAY
        else -> DayOfWeek.SUNDAY
    }

    /** Most recent sweep weekday on or before `now`'s local date. */
    fun mostRecentSweepAnchor(
        now: Instant,
        zoneId: ZoneId = ZoneId.systemDefault(),
        sweepWeekday: Int = RegistryRules.FADE_SWEEP_WEEKDAY.toInt(),
    ): LocalDate {
        val today = now.atZone(zoneId).toLocalDate()
        val target = sweepDayOfWeek(sweepWeekday)
        val delta = (today.dayOfWeek.value - target.value + 7) % 7
        return today.minusDays(delta.toLong())
    }

    /** Whether a faded task belongs to the current sweep (faded since the last completed sweep). */
    fun isInCurrentSweep(fadedAt: Instant?, lastSweepAt: Instant?): Boolean {
        if (fadedAt == null) return false
        if (lastSweepAt == null) return true
        return fadedAt.isAfter(lastSweepAt)
    }

    /**
     * Whether the weekly sweep banner should show on Today (`docs/TASK_FADE_SPEC.md` §5):
     * only on the sweep day itself (Sunday by default), when the user has not swept or
     * dismissed this week, and at least one task faded since the last sweep.
     */
    fun isSweepDue(
        now: Instant,
        lastSweepAt: Instant?,
        dismissedWeek: LocalDate?,
        fadedDates: List<Instant>,
        zoneId: ZoneId = ZoneId.systemDefault(),
        sweepWeekday: Int = RegistryRules.FADE_SWEEP_WEEKDAY.toInt(),
    ): Boolean {
        val today = now.atZone(zoneId).toLocalDate()
        val anchor = mostRecentSweepAnchor(now, zoneId, sweepWeekday)
        if (today != anchor) return false
        val anchorInstant = anchor.atStartOfDay(zoneId).toInstant()
        if (lastSweepAt != null && !lastSweepAt.isBefore(anchorInstant)) return false
        if (dismissedWeek != null && !dismissedWeek.isBefore(anchor)) return false
        return fadedDates.any { isInCurrentSweep(it, lastSweepAt) }
    }

    /** Plain-language one-line reason shown under a faded task in the sweep sheet. */
    fun sweepReason(
        touchedAt: Instant?,
        createdAt: Instant?,
        created: String?,
        listName: String?,
        scheduled: String?,
        now: Instant,
        inboxLabel: String = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX).orEmpty(),
        languageTag: String = "en",
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String {
        val parts = mutableListOf<String>()
        val clock = touchedAt
            ?: createdAt
            ?: created?.take(10)?.let { runCatching { LocalDate.parse(it).atStartOfDay(zoneId).toInstant() }.getOrNull() }
        if (clock != null) {
            val days = max(RegistryRules.FADE_WINDOW_DAYS.toInt(), Duration.between(clock, now).toDays().toInt())
            val fmt = fadeSweepText("daysWithoutActivity", languageTag).ifBlank { "{days} days without activity" }
            parts += fmt.replace("{days}", days.toString())
        }
        parts += if (!scheduled.isNullOrBlank()) {
            fadeSweepText("pastDate", languageTag).ifBlank { "Past date" }
        } else {
            fadeSweepText("noDate", languageTag).ifBlank { "No date" }
        }
        parts += listName?.takeIf(String::isNotBlank) ?: inboxLabel
        return parts.joinToString(" · ")
    }
}

/** Reads a localized string from the `fadeSweep` surface in `registry/surfaces.json`. */
internal fun fadeSweepText(field: String, languageTag: String): String {
    val raw = RegistryCatalog.surface(RegistrySurfaceIds.FADE_SWEEP)?.fields?.get(field).stringValue()
    return registryText(raw, languageTag)
}

/** Reads localized title, detail, and primaryTitle for a notice in `registry/surfaces.json` `notices.items`. */
internal data class RegistryNoticeCopy(
    val title: String,
    val detail: String,
    val primaryTitle: String,
)

internal fun registryNoticeCopy(noticeId: String, languageTag: String, count: Int = 1): RegistryNoticeCopy {
    val notices = RegistryCatalog.document("surfaces").fields["notices"] as? JsonValue.ObjectValue
    val items = (notices?.fields?.get("items") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = items.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == noticeId }
        as? JsonValue.ObjectValue
    val fields = entry?.fields.orEmpty()
    val rawTitle = when (val t = fields["title"]) {
        is JsonValue.StringValue -> t.value
        is JsonValue.ObjectValue -> {
            val key = if (count == 1) "one" else "other"
            t.fields[key].stringValue() ?: t.fields["other"].stringValue()
        }
        else -> null
    }
    val title = registryText(rawTitle, languageTag).replace("{count}", count.toString())
    val detail = registryText(fields["detail"].stringValue(), languageTag).replace("{count}", count.toString())
    val primary = registryText(fields["primaryTitle"].stringValue(), languageTag)
    return RegistryNoticeCopy(title = title, detail = detail, primaryTitle = primary)
}

/** Device-local sweep timestamps matching Apple `TaskFade.lastSweepAt` / `dismissedSweepWeek`. */
class FadeSweepStore(context: Context) {
    private val prefs = context.getSharedPreferences("septena_fade_sweep", Context.MODE_PRIVATE)

    fun lastSweepAt(): Instant? = prefs.getLong(KEY_LAST_SWEEP_MS, 0L)
        .takeIf { it > 0L }
        ?.let(Instant::ofEpochMilli)

    fun markSweepCompleted(at: Instant) {
        prefs.edit().putLong(KEY_LAST_SWEEP_MS, at.toEpochMilli()).apply()
    }

    fun dismissedSweepWeek(): LocalDate? = prefs.getString(KEY_DISMISSED_WEEK, null)
        ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }

    fun dismissSweepForCurrentWeek(now: Instant, zoneId: ZoneId = ZoneId.systemDefault()) {
        val anchor = FadeSweepRules.mostRecentSweepAnchor(now, zoneId)
        prefs.edit().putString(KEY_DISMISSED_WEEK, anchor.toString()).apply()
    }

    companion object {
        private const val KEY_LAST_SWEEP_MS = "last_sweep_at_ms"
        private const val KEY_DISMISSED_WEEK = "dismissed_sweep_week"
    }
}

/**
 * Quiet translucent banner card shown on Today on sweep day, or on the Faded
 * list on any day (`docs/TASK_FADE_SPEC.md` §5). "Sweep" is internal; UI says "Review".
 */
@Composable
internal fun FadeSweepBannerCard(
    message: String,
    reviewLabel: String,
    dismissLabel: String?,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onReview: () -> Unit,
    onDismiss: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    TaskCardSlice(
        position = TaskCardPosition.Solo,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = message,
                fontSize = 14.5.sp,
                lineHeight = 20.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Button(
                    onClick = onReview,
                    modifier = Modifier.heightIn(min = 42.dp),
                ) {
                    Text(reviewLabel)
                }
                if (dismissLabel != null && onDismiss != null) {
                    TextButton(
                        onClick = onDismiss,
                        modifier = Modifier.heightIn(min = 42.dp),
                    ) {
                        Text(dismissLabel)
                    }
                }
            }
        }
    }
}

/**
 * Weekly Sweep sheet mirroring Apple `TaskFadeSweepSheet.swift`:
 * shows faded tasks with one tap ("Keep") per item and one bottom button
 * ("Let the rest go") that cancels remaining tasks with `dropReason = "faded"`
 * as a single undo entry. Dismissing drops nothing.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TaskFadeSweepSheet(
    items: List<FadeSweepItem>,
    keepTitle: String,
    languageTag: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onKeep: (String) -> Unit,
    onLetRestGo: (List<String>) -> Unit,
    onMarkCompleted: () -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val remaining = remember(items) { mutableStateListOf<FadeSweepItem>().apply { addAll(items) } }
    var keptCount by remember(items) { mutableIntStateOf(0) }
    fun copy(field: String) = fadeSweepText(field, languageTag)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 20.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = copy("title"),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onDismiss) {
                    Text(copy("dismissTitle"))
                }
            }

            if (remaining.isEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp, vertical = 40.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CheckmarkGlyph(
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        size = 32.dp,
                    )
                    Text(
                        text = copy(if (keptCount > 0) "keptAllTitle" else "emptyTitle"),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    if (keptCount > 0) {
                        Text(
                            text = copy("keptAllDetail"),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            } else {
                Text(
                    text = copy("intro"),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 420.dp),
                ) {
                    itemsIndexed(remaining, key = { _, item -> item.id }) { index, item ->
                        TaskCardSlice(
                            position = cardPosition(index, remaining.size),
                            isSelected = false,
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                Column(
                                    modifier = Modifier.weight(1f),
                                    verticalArrangement = Arrangement.spacedBy(3.dp),
                                ) {
                                    Text(
                                        text = item.title,
                                        fontSize = 15.sp,
                                        lineHeight = 20.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(
                                        text = item.reason,
                                        fontSize = 12.5.sp,
                                        lineHeight = 16.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                                OutlinedButton(
                                    onClick = {
                                        onKeep(item.id)
                                        remaining.removeAll { it.id == item.id }
                                        keptCount += 1
                                    },
                                ) {
                                    Text(keepTitle)
                                }
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))
            HorizontalDivider()
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (remaining.isNotEmpty()) {
                    val remText = if (remaining.size == 1) {
                        copy("remainingOne")
                    } else {
                        copy("remainingOther").replace("{count}", remaining.size.toString())
                    }
                    Text(
                        text = remText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                    Button(
                        onClick = {
                            onLetRestGo(remaining.map(FadeSweepItem::id))
                            onMarkCompleted()
                            onDismiss()
                        },
                    ) {
                        Text(copy("letRestGoTitle"))
                    }
                } else {
                    Spacer(modifier = Modifier.weight(1f))
                    Button(
                        onClick = {
                            onMarkCompleted()
                            onDismiss()
                        },
                    ) {
                        Text(copy("doneTitle"))
                    }
                }
            }
        }
    }
}
