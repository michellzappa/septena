package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.booleanValue
import app.septena.core.longValue
import app.septena.core.stringValue

/**
 * A tester's beta state (`GET /v1/beta`, ADR 0064). The checklist is an ordinary project in
 * the tester's list that the server seeds; [projectId] names it, or is null when it is gone.
 * Every word on the Today card is in [copy] (`cardTitle`, `cardBody`, `cardOpen`, `cardDismiss`).
 */
data class BetaStatus(
    val projectId: String?,
    val cardDismissedAtMs: Long?,
    val copy: Map<String, String>,
) {
    fun text(id: String): String = copy[id].orEmpty()
}

/**
 * The beta endpoints (`GET /v1/beta`, `POST /v1/beta/progress`). Same bearer and
 * refresh-on-401 rule as [SeptenaAccessClient]. Throws [AccessHttpException].
 */
class SeptenaBetaClient(private val access: SeptenaAccessClient) {
    /** The tester's beta state, or null when the account is not a tester's (`{ member: false }`). */
    suspend fun status(platform: String = PLATFORM): BetaStatus? =
        parse(access.request("/v1/beta?platform=$platform", "GET", body = null))

    /** Closes the Today card for good (`{ dismissCard: true }`). */
    suspend fun dismissCard() {
        val body = JsonValue.ObjectValue(mapOf("dismissCard" to JsonValue.BooleanValue(true)))
        access.request("/v1/beta/progress", "POST", body.canonicalJson())
    }

    companion object {
        const val PLATFORM = "android"

        /** Reads the response; unknown keys are ignored. */
        fun parse(body: String): BetaStatus? {
            val json = JsonValue.parse(body) as? JsonValue.ObjectValue ?: return null
            if (json.fields["member"].booleanValue() != true) return null
            val copy = (json.fields["copy"] as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (key, value) -> value.stringValue()?.let { key to it } }
                .toMap()
            return BetaStatus(
                projectId = json.fields["projectId"].stringValue()?.takeIf(String::isNotBlank),
                cardDismissedAtMs = json.fields["cardDismissedAt"].longValue(),
                copy = copy,
            )
        }
    }
}
