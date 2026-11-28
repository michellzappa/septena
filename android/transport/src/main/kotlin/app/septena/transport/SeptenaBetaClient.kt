package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.booleanValue
import app.septena.core.longValue
import app.septena.core.stringValue

/** One checklist item (`GET /v1/beta` `items`). */
data class BetaItem(val id: String, val title: String, val tryText: String)

/**
 * A tester's checklist (`GET /v1/beta`, docs/BETA_ONBOARDING_SPEC.md §7). Every word on the
 * Beta row, screen and card is in [copy], keyed by the server's names (`settingsRow`, `deal`, ...).
 */
data class BetaChecklist(
    val joinedAtMs: Long?,
    val copy: Map<String, String>,
    val items: List<BetaItem>,
    /** Item id to the time it was ticked, ms since 1970. */
    val tried: Map<String, Long>,
    val ackAtMs: Long?,
    val cardDismissedAtMs: Long?,
    val feedbackUrl: String?,
) {
    fun text(id: String): String = copy[id].orEmpty()

    /** `settingsSummary` with `{tried}` and `{total}` filled in. */
    val summary: String
        get() = text("settingsSummary")
            .replace("{tried}", items.count { it.id in tried }.toString())
            .replace("{total}", items.size.toString())
}

/**
 * The beta checklist (`GET /v1/beta`, `POST /v1/beta/progress`). Same bearer and
 * refresh-on-401 rule as [SeptenaAccessClient]. Throws [AccessHttpException].
 */
class SeptenaBetaClient(private val access: SeptenaAccessClient) {
    /** The checklist, or null when the account is not a tester's (`{ member: false }`). */
    suspend fun checklist(platform: String = PLATFORM): BetaChecklist? =
        parse(access.request("/v1/beta?platform=$platform", "GET", body = null))

    suspend fun setTried(item: String, tried: Boolean) =
        progress("item" to JsonValue.StringValue(item), "tried" to JsonValue.BooleanValue(tried))

    suspend fun acknowledge() = progress("ack" to JsonValue.BooleanValue(true))

    suspend fun dismissCard() = progress("dismissCard" to JsonValue.BooleanValue(true))

    private suspend fun progress(vararg fields: Pair<String, JsonValue>) {
        access.request("/v1/beta/progress", "POST", JsonValue.ObjectValue(mapOf(*fields)).canonicalJson())
    }

    companion object {
        const val PLATFORM = "android"

        fun parse(body: String): BetaChecklist? {
            val json = JsonValue.parse(body) as? JsonValue.ObjectValue ?: return null
            if (json.fields["member"].booleanValue() != true) return null
            val copy = (json.fields["copy"] as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (key, value) -> value.stringValue()?.let { key to it } }
                .toMap()
            val items = (json.fields["items"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { raw ->
                val item = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                BetaItem(
                    id = item.fields["id"].stringValue() ?: return@mapNotNull null,
                    title = item.fields["title"].stringValue().orEmpty(),
                    tryText = item.fields["try"].stringValue().orEmpty(),
                )
            }
            val tried = (json.fields["tried"] as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (id, at) -> at.longValue()?.let { id to it } }
                .toMap()
            return BetaChecklist(
                joinedAtMs = json.fields["joinedAt"].longValue(),
                copy = copy,
                items = items,
                tried = tried,
                ackAtMs = json.fields["ackAt"].longValue(),
                cardDismissedAtMs = json.fields["cardDismissedAt"].longValue(),
                feedbackUrl = json.fields["feedbackURL"].stringValue(),
            )
        }
    }
}
