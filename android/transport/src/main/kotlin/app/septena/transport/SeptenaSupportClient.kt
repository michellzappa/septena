package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.stringValue
import java.io.IOException
import java.net.HttpURLConnection

/** One line of a Contact Support conversation (`GET /v1/support/messages`). */
data class SupportMessage(
    val id: String,
    /** `in` (the person's message) or `out` (a reply from Septena). */
    val direction: String,
    val text: String,
    val authorName: String?,
    val createdAtMs: Long,
    val readAtMs: Long?,
) {
    val isReply: Boolean get() = direction == "out"
}

data class SupportConversation(val messages: List<SupportMessage>, val unread: Int)

/** What "Include diagnostics" adds (docs/SUPPORT_SPEC.md §4). Never task content. */
data class SupportDiagnostics(
    val platform: String,
    val osVersion: String?,
    val deviceModel: String?,
    val appVersion: String?,
    val build: Long?,
    val signedIn: Boolean,
    val lastSyncAt: String?,
    val lastSyncError: String?,
)

/** Why a message did not go out; the screen keeps the text and says which. */
class SupportSendException(val reason: Reason) : IOException("Support message refused: $reason") {
    enum class Reason { EMAIL_REQUIRED, RATE_LIMITED, FAILED }
}

/**
 * Contact Support (ADR 0054, docs/IDENTIFIERS.md "Support wire"): `POST`/`GET /v1/support/messages`
 * and `POST /v1/support/read`. Signed in, it sends the bearer and the support key, so a signed-out
 * conversation moves to the account. Signed out, it sends the support key alone.
 */
class SeptenaSupportClient(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    suspend fun send(
        messageId: String,
        text: String,
        email: String?,
        diagnostics: SupportDiagnostics?,
        supportKey: String,
    ): SupportMessage {
        val fields = linkedMapOf<String, JsonValue>(
            "message_id" to JsonValue.StringValue(messageId),
            "text" to JsonValue.StringValue(text),
        )
        if (email != null) fields["email"] = JsonValue.StringValue(email)
        if (diagnostics != null) fields["diagnostics"] = diagnosticsJson(diagnostics)
        val response = request("/v1/support/messages", "POST", JsonValue.ObjectValue(fields).canonicalJson(), supportKey)
        when {
            response.statusCode == 202 -> {
                val json = JsonValue.parse(response.body) as? JsonValue.ObjectValue
                return message(json?.fields?.get("message")) ?: throw SupportSendException(SupportSendException.Reason.FAILED)
            }
            response.statusCode == 429 -> throw SupportSendException(SupportSendException.Reason.RATE_LIMITED)
            response.statusCode == 400 && errorCode(response.body) == "email_required" ->
                throw SupportSendException(SupportSendException.Reason.EMAIL_REQUIRED)
            else -> throw SupportSendException(SupportSendException.Reason.FAILED)
        }
    }

    suspend fun conversation(supportKey: String): SupportConversation {
        val response = request("/v1/support/messages", "GET", body = null, supportKey)
        if (response.statusCode != 200) throw AccessHttpException(response.statusCode, response.body)
        val json = JsonValue.parse(response.body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")
        val messages = (json.fields["messages"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull(::message)
        return SupportConversation(messages, json.fields["unread"].longValue()?.toInt() ?: 0)
    }

    suspend fun markRead(supportKey: String) {
        val response = request("/v1/support/read", "POST", body = null, supportKey)
        if (response.statusCode !in 200..299) throw AccessHttpException(response.statusCode, response.body)
    }

    private suspend fun request(path: String, method: String, body: String?, supportKey: String): HttpResponse {
        val headers = mapOf(SUPPORT_KEY_HEADER to supportKey)
        val token = credentials.accessToken()
        val first = JsonHttp.send(baseUrl, path, method, body, clientVersion, bearer = token, headers = headers)
        if (token == null || first.statusCode != HttpURLConnection.HTTP_UNAUTHORIZED) return first
        val renewed = credentials.refreshAfterUnauthorized() ?: return first
        return JsonHttp.send(baseUrl, path, method, body, clientVersion, bearer = renewed, headers = headers)
    }

    private fun diagnosticsJson(d: SupportDiagnostics): JsonValue.ObjectValue {
        val fields = linkedMapOf<String, JsonValue>("platform" to JsonValue.StringValue(d.platform))
        d.osVersion?.let { fields["osVersion"] = JsonValue.StringValue(it.take(40)) }
        d.deviceModel?.let { fields["deviceModel"] = JsonValue.StringValue(it.take(60)) }
        d.appVersion?.let { fields["appVersion"] = JsonValue.StringValue(it.take(40)) }
        d.build?.let { fields["build"] = JsonValue.IntegerValue(it) }
        fields["signedIn"] = JsonValue.BooleanValue(d.signedIn)
        d.lastSyncAt?.let { fields["lastSyncAt"] = JsonValue.StringValue(it.take(40)) }
        d.lastSyncError?.let { fields["lastSyncError"] = JsonValue.StringValue(it.take(80)) }
        return JsonValue.ObjectValue(fields)
    }

    private fun message(raw: JsonValue?): SupportMessage? {
        val fields = (raw as? JsonValue.ObjectValue)?.fields ?: return null
        return SupportMessage(
            id = fields["id"].stringValue() ?: return null,
            direction = fields["direction"].stringValue() ?: return null,
            text = fields["text"].stringValue().orEmpty(),
            authorName = fields["authorName"].stringValue(),
            createdAtMs = fields["createdAt"].longValue() ?: 0L,
            readAtMs = fields["readAt"].longValue(),
        )
    }

    private fun errorCode(body: String): String? = runCatching {
        ((JsonValue.parse(body) as? JsonValue.ObjectValue)?.fields?.get("error")).stringValue()
    }.getOrNull()

    private fun JsonValue?.longValue(): Long? = when (this) {
        is JsonValue.IntegerValue -> value
        is JsonValue.DecimalValue -> value.toLong()
        else -> null
    }

    companion object {
        const val SUPPORT_KEY_HEADER = "X-Septena-Support-Key"
        /** The backend's limit (`MESSAGE_MAX_CHARS`). */
        const val MESSAGE_MAX_CHARS = 4_000
    }
}
