package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.booleanValue
import app.septena.core.stringValue
import java.io.IOException
import java.net.HttpURLConnection

/** One app install signed in to the account (`GET /v1/access`, `devices`). */
data class AccessDevice(
    val sid: String,
    /** The device's `X-Septena-Client` string, or null when the server never saw one. */
    val client: String?,
    val firstSeenMs: Long,
    val lastSeenMs: Long,
    val current: Boolean,
    val syncing: Boolean,
)

/** One connected agent: an MCP connection (`GET /v1/access`, `connections`). */
data class AgentConnection(
    val id: String,
    /** The display name: the user's name for the agent, else [clientName]. */
    val name: String,
    val clientName: String,
    val scope: String?,
    val createdAtMs: Long,
    val lastUsedMs: Long,
)

data class AccountAccess(
    val devices: List<AccessDevice>,
    val connections: List<AgentConnection>,
    /** `agents.count`; an old server leaves it out, so it falls back to the number of connections. */
    val agentCount: Int,
)

class AccessHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena access returned HTTP $statusCode",
)

/**
 * Devices and agents that can reach the account (docs/SEPTASK_BACKEND.md §10).
 * Routes: `GET /v1/access`, `DELETE /v1/access/devices/:sid`,
 * `DELETE /v1/access/connections/:id`, `PATCH /v1/access/connections/:id`.
 * Same bearer and refresh-on-401 rule as [UrlConnectionSyncTransport].
 */
class SeptenaAccessClient(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    suspend fun access(): AccountAccess {
        val json = JsonValue.parse(request("/v1/access", "GET", body = null)) as? JsonValue.ObjectValue
            ?: error("Expected a JSON object")
        val devices = json.array("devices").mapNotNull { raw ->
            val device = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            AccessDevice(
                sid = device.fields["sid"].stringValue() ?: return@mapNotNull null,
                client = device.fields["client"].stringValue(),
                firstSeenMs = device.fields["firstSeen"].longValue() ?: 0L,
                lastSeenMs = device.fields["lastSeen"].longValue() ?: 0L,
                current = device.fields["current"].booleanValue() ?: false,
                syncing = device.fields["syncing"].booleanValue() ?: true,
            )
        }
        val connections = json.array("connections").mapNotNull { raw ->
            val connection = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val clientName = connection.fields["clientName"].stringValue().orEmpty()
            AgentConnection(
                id = connection.fields["id"].stringValue() ?: return@mapNotNull null,
                name = connection.fields["name"].stringValue()?.takeIf(String::isNotEmpty) ?: clientName,
                clientName = clientName,
                scope = connection.fields["scope"].stringValue(),
                createdAtMs = connection.fields["createdAt"].longValue() ?: 0L,
                lastUsedMs = connection.fields["lastUsed"].longValue() ?: 0L,
            )
        }
        val agents = json.fields["agents"] as? JsonValue.ObjectValue
        return AccountAccess(
            devices = devices,
            connections = connections,
            agentCount = agents?.fields?.get("count").longValue()?.toInt() ?: connections.size,
        )
    }

    /** Signs out another device. The server refuses the current one (400 `current_device`). */
    suspend fun signOutDevice(sid: String) {
        request("/v1/access/devices/${sid.pathSegment()}", "DELETE", body = null)
    }

    suspend fun disconnect(connectionId: String) {
        request("/v1/access/connections/${connectionId.pathSegment()}", "DELETE", body = null)
    }

    /** A null or blank [name] gives the agent its client's name back. */
    suspend fun renameAgent(connectionId: String, name: String?) {
        val trimmed = name?.trim()?.take(MAX_AGENT_NAME)?.takeIf(String::isNotEmpty)
        val body = JsonValue.ObjectValue(mapOf("name" to JsonValue.stringOrNull(trimmed))).canonicalJson()
        request("/v1/access/connections/${connectionId.pathSegment()}", "PATCH", body)
    }

    private suspend fun request(path: String, method: String, body: String?): String {
        val firstToken = credentials.accessToken() ?: throw SyncAuthenticationException()
        val first = JsonHttp.send(baseUrl, path, method, body, clientVersion, bearer = firstToken)
        val final = if (first.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            val renewed = credentials.refreshAfterUnauthorized() ?: throw SyncAuthenticationException()
            JsonHttp.send(baseUrl, path, method, body, clientVersion, bearer = renewed)
        } else {
            first
        }
        if (final.statusCode !in 200..299) throw AccessHttpException(final.statusCode, final.body)
        return final.body
    }

    private fun String.pathSegment(): String =
        java.net.URLEncoder.encode(this, Charsets.UTF_8.name()).replace("+", "%20")

    private fun JsonValue.ObjectValue.array(key: String): List<JsonValue?> =
        (fields[key] as? JsonValue.ArrayValue)?.values.orEmpty()

    private fun JsonValue?.longValue(): Long? = when (this) {
        is JsonValue.IntegerValue -> value
        is JsonValue.DecimalValue -> value.toLong()
        else -> null
    }

    private companion object {
        const val MAX_AGENT_NAME = 40
    }
}
