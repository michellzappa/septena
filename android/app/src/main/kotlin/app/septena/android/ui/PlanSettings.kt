package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.android.sync.SyncState
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.booleanValue
import app.septena.core.stringValue
import app.septena.transport.AccountEntitlement
import java.text.DateFormat
import java.util.Date

/** The account's plan, as the server reports it (ADR 0010, ADR 0023). Same cases as iOS `PlanStatus.Plan`. */
internal sealed interface AccountPlan {
    /** No account on this device: the full app, local only. */
    data object Device : AccountPlan

    /** Signed in, no active entitlement. */
    data class Free(val lapsed: Boolean) : AccountPlan

    /** The reverse trial: Plus limits, nothing paid. */
    data class Trial(val endsAtMs: Long) : AccountPlan

    /**
     * An active entitlement; [paidThroughMs] is null for a grant with no expiry. Pro
     * (ADR 0045) has every Plus limit or more, so only the words differ.
     */
    data class Plus(val paidThroughMs: Long?, val source: String, val isPro: Boolean = false) : AccountPlan
}

/** Reads the plan from `GET /v1/entitlement`. The server decides access; this only reads its answer. */
internal class PlanSettingsModel(private val graph: AndroidAppGraph) {
    /** Null until the first answer. Views show nothing for an unknown plan rather than guess. */
    var plan by mutableStateOf<AccountPlan?>(null)
        private set

    suspend fun refresh(signedIn: Boolean) {
        if (!signedIn) {
            plan = AccountPlan.Device
            return
        }
        try {
            plan = accountPlan(graph.access.entitlement())
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            // A failed read keeps the last known plan (iOS `PlanStatus.refresh`).
        }
    }

    val isPro: Boolean get() = (plan as? AccountPlan.Plus)?.isPro == true

    val isPlus: Boolean get() = plan is AccountPlan.Plus || plan is AccountPlan.Trial

    /**
     * The name of the plan page and its Settings row (iOS `PlanStatus.title`): Plus is the
     * offer, and an account on Pro sees its own plan.
     */
    fun title(languageTag: String): String =
        if (isPro) proCard(languageTag, "title") else plansText(languageTag, "name")

    /** One status line for Settings (`statusKey: planStatus`), from plans.json `status`. */
    fun statusLine(languageTag: String): String? = when (val current = plan) {
        AccountPlan.Device -> plansText(languageTag, "status", "device")
        is AccountPlan.Free -> plansText(languageTag, "status", "free")
        is AccountPlan.Trial -> plansText(languageTag, "status", "trialEnds").replace("{date}", day(current.endsAtMs))
        is AccountPlan.Plus -> current.paidThroughMs?.let {
            plansText(languageTag, "status", if (current.isPro) "proThrough" else "paidThrough").replace("{date}", day(it))
        } ?: if (current.isPro) plansText(languageTag, "proName") else plansText(languageTag, "status", "plus")
        null -> null
    }

    companion object {
        const val PLAN_STATUS_KEY = "planStatus"
        const val PAGE = "plus"

        fun accountPlan(answer: AccountEntitlement): AccountPlan {
            val live = answer.rows.filter { it.active }
            if (!answer.active || live.isEmpty()) {
                return AccountPlan.Free(lapsed = answer.rows.any { it.source != TRIAL })
            }
            val isPro = answer.plan == PRO
            // The words name the plan the account is on, so its rows give the date.
            val paid = live.filter { if (isPro) it.plan == PRO else it.source != TRIAL }
            if (paid.isEmpty()) {
                val end = answer.trialEndsAtMs ?: live.mapNotNull { it.expiresAtMs }.maxOrNull() ?: 0L
                return AccountPlan.Trial(end)
            }
            paid.firstOrNull { it.expiresAtMs == null }?.let { return AccountPlan.Plus(null, it.source, isPro) }
            val latest = paid.maxBy { it.expiresAtMs ?: 0L }
            return AccountPlan.Plus(latest.expiresAtMs, latest.source, isPro)
        }

        private const val TRIAL = "trial"
        private const val PRO = "pro"

        private fun day(ms: Long): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(ms))
    }
}

/** The sync status word for `statusKey: syncStatus` (iOS `liveSyncSummary`). */
internal fun syncStatusLine(signedIn: Boolean, state: SyncState, languageTag: String): String {
    if (!signedIn) return plansText(languageTag, "status", "device")
    // The server does not sync this device: say where the tasks are (iOS `liveSyncSummary`).
    if (state == SyncState.NotSyncing) return plansText(languageTag, "status", "device")
    val id = when (state) {
        SyncState.Syncing -> "syncing"
        is SyncState.Failed -> "offline"
        SyncState.NeedsSignIn -> "needsSignIn"
        SyncState.Idle, is SyncState.Synced -> "synced"
        SyncState.NotSyncing -> "offline"
    }
    return settingsCopy(SYNC_STATUS_KEY, id, languageTag)
}

internal const val SYNC_STATUS_KEY = "syncStatus"

/**
 * Surface `account_profile_card`: the root row that opens Account. The name the user
 * gave, the plan, and the sync state; signed out, "On this device · Sign in to sync".
 */
@Composable
internal fun AccountProfileCard(
    name: String,
    signedIn: Boolean,
    plans: PlanSettingsModel,
    syncState: SyncState,
    languageTag: String,
    onClick: () -> Unit,
) {
    val title = name.trim().ifEmpty { settingsCopy(ACCOUNT_CARD, "yourProfile", languageTag) }
    val detail = if (signedIn) {
        val plan = when {
            plans.isPro -> plansText(languageTag, "proName")
            plans.isPlus -> plansText(languageTag, "shortName")
            else -> plansText(languageTag, "status", "free")
        }
        "$plan · ${syncStatusLine(signedIn = true, state = syncState, languageTag = languageTag)}"
    } else {
        settingsCopy(ACCOUNT_CARD, "signInToSync", languageTag)
    }
    ListItem(
        headlineContent = { Text(title, style = MaterialTheme.typography.titleMedium) },
        supportingContent = { Text(detail) },
        trailingContent = { Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    )
}

private const val ACCOUNT_CARD = "account_profile_card"

/**
 * Surface `plus_offer` (Settings ▸ Account ▸ Septena Plus): the account's plan and what
 * Plus adds, from registry/plans.json, like iOS `SeptaskPlusPane`. It sells nothing:
 * the Google Play purchase is #176.
 */
@Composable
internal fun PlusOffer(plans: PlanSettingsModel, languageTag: String, syncState: SyncState? = null) {
    val document = RegistryCatalog.document("plans")
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            if (plans.isPro) proCard(languageTag, "title") else plansText(languageTag, "headline"),
            style = MaterialTheme.typography.titleLarge,
        )
        Text(
            if (plans.isPro) proCard(languageTag, "detail") else plansText(languageTag, "subhead"),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
    plans.statusLine(languageTag)?.let { line ->
        ListItem(
            headlineContent = { Text(plansText(languageTag, "labels", "yourPlan")) },
            trailingContent = { Text(line, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        )
    }
    // The second-device moment (iOS `SeptaskPlusPane`): the server answered HTTP 402 to sync.
    if (syncState == SyncState.NotSyncing) {
        planUpsell("second_device", languageTag)?.let { (title, detail) ->
            ListItem(
                headlineContent = { Text(title) },
                supportingContent = { Text(detail) },
            )
        }
    }
    HorizontalDivider()

    // What each plan above the account's costs (ADR 0059): Plus and Pro, or only Pro on Plus.
    if (!plans.isPro) {
        if (!plans.isPlus || plans.plan is AccountPlan.Trial) PlanPrices(document, "prices", plansText(languageTag, "name"), languageTag)
        PlanPrices(document, "proPrices", proCard(languageTag, "title"), languageTag, proCard(languageTag, "detail"))
    }

    if (plans.plan == AccountPlan.Device) {
        ListItem(
            headlineContent = { Text(plansText(languageTag, "trial", "title")) },
            supportingContent = { Text(plansText(languageTag, "trial", "detail")) },
        )
    }

    // The account's plan next to the plan below it.
    val freeTitle = planCard("free", "title", languageTag)
    val plusTitle = plansText(languageTag, "shortName")
    val columns = if (plans.isPro) {
        listOf("plus" to plusTitle, "pro" to plansText(languageTag, "proName"))
    } else {
        listOf("free" to freeTitle, "plus" to plusTitle)
    }
    document.objects("outcomes").forEach { outcome ->
        HorizontalDivider()
        SectionHeader(registryText(outcome.fields["title"].stringValue(), languageTag))
        outcome.objects("rows").forEach { row ->
            val cells = row.fields["cells"] as? JsonValue.ObjectValue
            val planned = row.fields["status"].stringValue() == "planned"
            ListItem(
                headlineContent = { Text(registryText(row.fields["label"].stringValue(), languageTag)) },
                supportingContent = {
                    Column {
                        columns.forEach { (id, title) ->
                            Text("$title: ${planCell(cells?.fields?.get(id), languageTag)}")
                        }
                        if (planned) {
                            Text(
                                plansText(languageTag, "labels", "planned"),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
            )
        }
        SectionFooter(registryText(outcome.fields["detail"].stringValue(), languageTag))
    }

    HorizontalDivider()
    document.objects("promises").forEach { promise ->
        ListItem(
            headlineContent = { Text(registryText(promise.fields["title"].stringValue(), languageTag)) },
            supportingContent = { Text(registryText(promise.fields["detail"].stringValue(), languageTag)) },
        )
    }
}

/** What one plan costs (`prices` for Plus, `proPrices` for Pro). An account on Pro sees neither. */
@Composable
private fun PlanPrices(document: JsonValue.ObjectValue, key: String, title: String, languageTag: String, detail: String? = null) {
    SectionHeader(title)
    detail?.let { SectionFooter(it) }
    document.objects(key).forEach { price ->
        val highlighted = price.fields["highlighted"].booleanValue() == true
        ListItem(
            headlineContent = {
                Text(
                    registryText(price.fields["label"].stringValue(), languageTag),
                    fontWeight = if (highlighted) FontWeight.SemiBold else FontWeight.Normal,
                )
            },
            supportingContent = { Text(registryText(price.fields["detail"].stringValue(), languageTag)) },
        )
    }
    // One checkout line under the last plan, not one per plan.
    if (key != "proPrices") return
    val checkoutOpen = (document.fields["checkout"] as? JsonValue.ObjectValue)?.fields?.get("open").booleanValue() == true
    SectionFooter(if (checkoutOpen) plansText(languageTag, "priceFootnote") else plansText(languageTag, "checkout", "notice"))
}

/** Title and detail of a plans.json `upsells` note, localized; null when the id is unknown. */
internal fun planUpsell(id: String, languageTag: String): Pair<String, String>? =
    RegistryCatalog.document("plans").objects("upsells").firstOrNull { it.fields["id"].stringValue() == id }
        ?.let { registryText(it.fields["title"].stringValue(), languageTag) to registryText(it.fields["detail"].stringValue(), languageTag) }

/** A field of a plan card (plans.json `cards`). Pro has one; the paywalls offer it in #719 (ADR 0059). */
private fun planCard(id: String, field: String, languageTag: String): String =
    RegistryCatalog.document("plans").objects("cards").firstOrNull { it.fields["id"].stringValue() == id }
        ?.let { registryText(it.fields[field].stringValue(), languageTag) }.orEmpty()

private fun proCard(languageTag: String, field: String): String = planCard("pro", field, languageTag)

/** One comparison cell: included, not included, or the registry's text. */
private fun planCell(cell: JsonValue?, languageTag: String): String = when (cell) {
    is JsonValue.BooleanValue -> plansText(languageTag, "labels", if (cell.value) "included" else "notIncluded")
    else -> registryText(cell.stringValue(), languageTag)
}

private fun JsonValue.ObjectValue.objects(key: String): List<JsonValue.ObjectValue> =
    (fields[key] as? JsonValue.ArrayValue)?.values.orEmpty().filterIsInstance<JsonValue.ObjectValue>()

@Composable
internal fun SectionHeader(text: String) {
    if (text.isEmpty()) return
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(start = 16.dp, top = 14.dp, bottom = 2.dp),
    )
}

@Composable
internal fun SectionFooter(text: String) {
    if (text.isEmpty()) return
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
    )
}
