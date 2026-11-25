package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.ProjectShare
import app.septena.core.ShareInviteLink
import app.septena.core.stringValue

/** An invite nobody used yet. */
data class ShareInvite(val id: String, val expiresAtMs: Long)

/** `GET /v1/shares/:id`. Only the owner gets invites. */
data class ShareDetails(val share: ProjectShare, val invites: List<ShareInvite>)

/** A new invite. The URL is shown once. */
data class NewShareInvite(val invite: ShareInvite, val url: String)

/** What an invite leads to, before someone accepts it. */
data class SharePreview(val title: String, val from: String)

/** Shared projects (`/v1/shares`, docs/PROJECT_SHARING_SPEC.md §5). Throws [AccessHttpException]. */
class SeptenaShareClient(private val access: SeptenaAccessClient) {
    suspend fun create(projectId: String, name: String): ProjectShare =
        share(json(access.request("/v1/shares", "POST", body("projectId" to projectId, "name" to name))))

    suspend fun details(shareId: String): ShareDetails {
        val json = json(access.request("/v1/shares/$shareId", "GET", body = null))
        val invites = (json.fields["invites"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull(::invite)
        return ShareDetails(share(json), invites)
    }

    suspend fun invite(shareId: String): NewShareInvite {
        val json = json(access.request("/v1/shares/$shareId/invites", "POST", body = null))
        return NewShareInvite(
            invite = invite(json.fields["invite"]) ?: error("An invite without an id"),
            url = json.fields["url"].stringValue() ?: error("An invite without a link"),
        )
    }

    suspend fun revokeInvite(shareId: String, inviteId: String) {
        access.request("/v1/shares/$shareId/invites/$inviteId", "DELETE", body = null)
    }

    /** The owner removes a member; a member leaves with their own id. */
    suspend fun endMembership(shareId: String, memberId: String) {
        access.request("/v1/shares/$shareId/members/$memberId", "DELETE", body = null)
    }

    suspend fun stop(shareId: String) {
        access.request("/v1/shares/$shareId", "DELETE", body = null)
    }

    suspend fun preview(token: String): SharePreview {
        val json = json(access.request("/v1/shares/preview", "POST", body("token" to token)))
        return SharePreview(json.fields["title"].stringValue().orEmpty(), json.fields["from"].stringValue().orEmpty())
    }

    suspend fun join(token: String, name: String) {
        access.request("/v1/shares/join", "POST", body("token" to token, "name" to name))
    }

    private fun share(json: JsonValue.ObjectValue): ProjectShare =
        ProjectShare.from(json.fields["share"]) ?: error("A share without its members")

    private fun invite(raw: JsonValue?): ShareInvite? {
        val fields = (raw as? JsonValue.ObjectValue)?.fields ?: return null
        val expires = when (val value = fields["expiresAt"]) {
            is JsonValue.IntegerValue -> value.value
            is JsonValue.DecimalValue -> value.value.toLong()
            else -> 0L
        }
        return ShareInvite(fields["id"].stringValue() ?: return null, expires)
    }

    private fun json(body: String): JsonValue.ObjectValue =
        JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")

    private fun body(vararg fields: Pair<String, String>): String =
        JsonValue.ObjectValue(fields.associate { (key, value) -> key to JsonValue.StringValue(value) }).canonicalJson()

    companion object {
        private val HOST = java.net.URI(JsonHttp.DEFAULT_BASE_URL).host

        /** The invite token in a pasted or opened link, or null. */
        fun inviteToken(link: String): String? = ShareInviteLink.token(link, HOST)
    }
}
