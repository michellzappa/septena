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

/** One row of `GET /v1/entitlement` `entitlements` (ADR 0026). */
data class EntitlementRow(
    /** `apple` / `stripe` / `google` / `grant` / `trial`. */
    val source: String,
    /** ms since 1970; null means no expiry (a grant). */
    val expiresAtMs: Long?,
    val active: Boolean,
    /** The plan the row gives; null means Plus (ADR 0045). */
    val plan: String? = null,
)

/**
 * The account's plan as the server reports it (`GET /v1/entitlement`). The server owns
 * the plan; the app only reads it to say which plan the account is on.
 */
data class AccountEntitlement(
    val active: Boolean,
    /** The plan the account is on: `free`, `plus` or `pro`. */
    val plan: String?,
    val rows: List<EntitlementRow>,
    /** ms since 1970: the reverse trial's end while it is the only active row. */
    val trialEndsAtMs: Long?,
    val enforced: Boolean,
    /** This device holds a sync slot; null when an older server does not say. */
    val deviceSyncing: Boolean?,
)

/** The private calendar feed (`GET /v1/ical/settings`). [scope] is `all` or `timed`. */
data class IcalFeed(
    val enabled: Boolean,
    val scope: String,
    val webcalUrl: String?,
)

/** One linked sign-in method on the signed-in account (`GET /v1/auth/identities`, #643). */
data class LinkedIdentity(
    val id: String,
    val provider: String,
    val label: String,
    val createdAtMs: Long,
)

data class LinkedIdentities(
    val identities: List<LinkedIdentity>,
    val canRemove: Boolean,
)

/** What a sign-in code asks for (`POST /v1/pair/inspect`), shown before the user approves it. */
data class PairingRequest(
    /** `device` (a new device signs in) or `connector` (Claude gets task access). */
    val kind: String,
    /** The requester's own name: "Android SM-A175F", or "Claude". */
    val client: String,
) {
    val isConnector: Boolean get() = kind == KIND_CONNECTOR

    companion object {
        const val KIND_CONNECTOR = "connector"
        const val KIND_DEVICE = "device"
    }
}

class AccessHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena access returned HTTP $statusCode",
) {
    /** The server's `error` code (`invalid_code`, `code_used`, `too_many_attempts`, ...), when the body has one. */
    val errorCode: String?
        get() = runCatching {
            ((JsonValue.parse(responseBody) as? JsonValue.ObjectValue)?.fields?.get("error")).stringValue()
        }.getOrNull()
}

/**
 * A sign-in code as people type or scan it (ADR 0016). Same rules as the backend's
 * `normalizePairCode` and Apple's `SeptaskSignInCodeScanner.code(from:)`.
 */
object PairCode {
    /** Uppercases and drops spaces and dashes. Null unless the result is 8 characters. */
    fun normalized(input: String): String? {
        val code = input.uppercase().filter { !it.isWhitespace() && it != '-' }
        return code.takeIf { it.length == CODE_LENGTH }
    }

    /**
     * The code in a scanned QR: `https://api.septena.app/pair/<CODE>` (only that host
     * and path) or a bare code. Anything else is null. A scan only fills in the code.
     */
    fun fromScan(payload: String, baseUrl: String = JsonHttp.DEFAULT_BASE_URL): String? {
        val text = payload.trim()
        val uri = runCatching { java.net.URI(text) }.getOrNull()
        if (uri?.scheme != null) {
            val host = runCatching { java.net.URI(baseUrl).host }.getOrNull()
            if (uri.scheme != "https" || host == null || !uri.host.equals(host, ignoreCase = true)) return null
            val parts = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
            if (parts.size != 2 || parts[0] != "pair") return null
            return normalized(parts[1])
        }
        return normalized(text)
    }

    private const val CODE_LENGTH = 8
}

/**
 * Devices and agents that can reach the account (docs/SEPTASK_BACKEND.md §10).
 * Routes: `GET /v1/access`, `DELETE /v1/access/devices/:sid`,
 * `DELETE /v1/access/connections/:id`, `PATCH /v1/access/connections/:id`,
 * `POST /v1/access/keys`.
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

    /**
     * Creates an agent key with read and write access (`POST /v1/access/keys`, #86).
     * Returns the key, which the server sends in this reply only.
     */
    suspend fun createAgentKey(name: String): String {
        val trimmed = name.trim().take(MAX_AGENT_NAME)
        require(trimmed.isNotEmpty()) { "An agent key needs a name" }
        val body = JsonValue.ObjectValue(
            mapOf("name" to JsonValue.StringValue(trimmed), "access" to JsonValue.StringValue("write")),
        ).canonicalJson()
        val json = JsonValue.parse(request("/v1/access/keys", "POST", body)) as? JsonValue.ObjectValue
            ?: error("Expected a JSON object")
        return json.fields["key"].stringValue()?.takeIf { it.startsWith("sk1.") }
            ?: error("The server sent no agent key")
    }

    /** What a sign-in code asks for. Throws [AccessHttpException] with `invalid_code` and the like. */
    suspend fun inspectPairing(code: String): PairingRequest {
        val body = JsonValue.ObjectValue(mapOf("code" to JsonValue.StringValue(code))).canonicalJson()
        val json = JsonValue.parse(request("/v1/pair/inspect", "POST", body)) as? JsonValue.ObjectValue
            ?: error("Expected a JSON object")
        return PairingRequest(
            kind = json.fields["kind"].stringValue() ?: error("A sign-in request without a kind"),
            client = json.fields["client"].stringValue().orEmpty(),
        )
    }

    /**
     * Approves a sign-in code for the [kind] the user confirmed; the server approves
     * nothing if the code is of another kind. Sends the device time zone, which decides
     * what "today" means for the connector. For a connector code, [agentName] names the
     * new agent and [replaces] is the agent (connection id) it takes the place of.
     */
    suspend fun approvePairing(code: String, kind: String, agentName: String? = null, replaces: String? = null) {
        val fields = buildMap<String, JsonValue> {
            put("code", JsonValue.StringValue(code))
            put("timeZone", JsonValue.StringValue(java.util.TimeZone.getDefault().id.take(MAX_TIME_ZONE)))
            put("kind", JsonValue.StringValue(kind))
            if (kind == PairingRequest.KIND_CONNECTOR) {
                agentName?.trim()?.take(MAX_AGENT_NAME)?.takeIf(String::isNotEmpty)
                    ?.let { put("name", JsonValue.StringValue(it)) }
                replaces?.let { put("replaces", JsonValue.StringValue(it)) }
            }
        }
        request("/v1/pair/approve", "POST", JsonValue.ObjectValue(fields).canonicalJson())
    }

    suspend fun entitlement(): AccountEntitlement {
        val json = JsonValue.parse(request("/v1/entitlement", "GET", body = null)) as? JsonValue.ObjectValue
            ?: error("Expected a JSON object")
        val rows = json.array("entitlements").mapNotNull { raw ->
            val row = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            EntitlementRow(
                source = row.fields["source"].stringValue() ?: return@mapNotNull null,
                expiresAtMs = row.fields["expiresAt"].longValue(),
                active = row.fields["active"].booleanValue() ?: false,
                plan = row.fields["plan"].stringValue(),
            )
        }
        val device = json.fields["device"] as? JsonValue.ObjectValue
        return AccountEntitlement(
            active = json.fields["active"].booleanValue() ?: false,
            plan = json.fields["plan"].stringValue(),
            rows = rows,
            trialEndsAtMs = json.fields["trialEndsAt"].longValue(),
            enforced = json.fields["enforced"].booleanValue() ?: false,
            deviceSyncing = device?.fields?.get("syncing").booleanValue(),
        )
    }

    suspend fun icalFeed(): IcalFeed = parseIcal(request("/v1/ical/settings", "GET", body = null))

    /** Turns the feed on or off, changes its scope, or rotates its link. Null fields stay as they are. */
    suspend fun updateIcalFeed(enabled: Boolean? = null, scope: String? = null, rotate: Boolean? = null): IcalFeed {
        val fields = buildMap<String, JsonValue> {
            enabled?.let { put("enabled", JsonValue.BooleanValue(it)) }
            scope?.let { put("scope", JsonValue.StringValue(it)) }
            rotate?.let { put("rotate", JsonValue.BooleanValue(it)) }
        }
        return parseIcal(request("/v1/ical/settings", "POST", JsonValue.ObjectValue(fields).canonicalJson()))
    }

    /** Lists linked sign-in methods on the signed-in account (`GET /v1/auth/identities`, #643). */
    suspend fun listIdentities(): LinkedIdentities = parseIdentities(request("/v1/auth/identities", "GET", body = null))

    /** Removes one sign-in method (`DELETE /v1/auth/identities/:id`); refuses the last one (409 `last_method`). */
    suspend fun unlinkIdentity(id: String): LinkedIdentities =
        parseIdentities(request("/v1/auth/identities/${id.pathSegment()}", "DELETE", body = null))

    /** Sends a 6-digit verification code to add an email address to the signed-in account. */
    suspend fun startLinkEmail(email: String) {
        val body = JsonValue.ObjectValue(mapOf("email" to JsonValue.StringValue(email))).canonicalJson()
        request("/v1/auth/link/email/start", "POST", body)
    }

    /** Verifies the emailed 6-digit code and links the email to the signed-in account. */
    suspend fun verifyLinkEmail(email: String, code: String): LinkedIdentities {
        val body = JsonValue.ObjectValue(
            mapOf("email" to JsonValue.StringValue(email), "code" to JsonValue.StringValue(code)),
        ).canonicalJson()
        return parseIdentities(request("/v1/auth/link/email/verify", "POST", body))
    }

    /** Starts an OIDC redirect URL to link Apple, Google or Microsoft to the signed-in account. */
    suspend fun startLinkOidc(provider: String, returnTo: String): String {
        val body = JsonValue.ObjectValue(
            mapOf("provider" to JsonValue.StringValue(provider), "returnTo" to JsonValue.StringValue(returnTo)),
        ).canonicalJson()
        val json = JsonValue.parse(request("/v1/auth/link/oidc/start", "POST", body)) as? JsonValue.ObjectValue
            ?: error("Expected a JSON object")
        return json.fields["url"].stringValue() ?: error("Link start response is missing url")
    }

    /** Completes an OIDC link callback (`POST /v1/auth/oidc/redeem` with Bearer). */
    suspend fun redeemOidcLink(code: String): LinkedIdentities {
        val body = JsonValue.ObjectValue(mapOf("code" to JsonValue.StringValue(code))).canonicalJson()
        return parseIdentities(request("/v1/auth/oidc/redeem", "POST", body))
    }

    private fun parseIdentities(body: String): LinkedIdentities {
        val json = JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")
        val list = json.array("identities").mapNotNull { raw ->
            val obj = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            LinkedIdentity(
                id = obj.fields["id"].stringValue() ?: return@mapNotNull null,
                provider = obj.fields["provider"].stringValue() ?: return@mapNotNull null,
                label = obj.fields["label"].stringValue().orEmpty(),
                createdAtMs = obj.fields["createdAt"].longValue() ?: 0L,
            )
        }
        return LinkedIdentities(
            identities = list,
            canRemove = json.fields["canRemove"].booleanValue() ?: (list.size > 1),
        )
    }

    /** The agent brief for the task tools (`GET /skill.md`, public, markdown). */
    suspend fun skillBrief(): String {
        val response = JsonHttp.send(baseUrl, "/skill.md", "GET", body = null, clientVersion = clientVersion)
        if (response.statusCode !in 200..299) throw AccessHttpException(response.statusCode, response.body)
        return response.body
    }

    private fun parseIcal(body: String): IcalFeed {
        val json = JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")
        return IcalFeed(
            enabled = json.fields["enabled"].booleanValue() ?: false,
            scope = json.fields["scope"].stringValue() ?: "all",
            webcalUrl = json.fields["webcalUrl"].stringValue(),
        )
    }

    /** Also the transport of [SeptenaShareClient]. */
    internal suspend fun request(path: String, method: String, body: String?): String {
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
        const val MAX_TIME_ZONE = 64
    }
}
