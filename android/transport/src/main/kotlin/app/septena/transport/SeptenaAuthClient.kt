package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.stringValue
import java.io.IOException

/** An app session from the backend (`issueSession` in backend/src/api/session.ts). */
data class SessionTokens(
    val accessToken: String,
    val refreshToken: String,
    val expiresInSeconds: Long,
    val userId: String,
)

/** A pending device sign-in: the code the user types into a signed-in app, and the secret only this device holds. */
data class DeviceCode(
    val code: String,
    val pollSecret: String,
    val expiresInSeconds: Long,
    val intervalSeconds: Long,
) {
    /** The code as the backend's pairing page shows it: `ABCD-EFGH`. */
    val displayCode: String get() = if (code.length == 8) code.take(4) + "-" + code.drop(4) else code
}

sealed interface DevicePollResult {
    data object Pending : DevicePollResult
    data object Expired : DevicePollResult
    data class Approved(val tokens: SessionTokens) : DevicePollResult
}

class AuthHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena sign-in returned HTTP $statusCode",
)

/**
 * Sign-in by device approval (ADR 0016, issue #170) and session refresh.
 * Routes: `/v1/auth/device/start`, `/v1/auth/device/poll`, `/v1/auth/refresh`, `/v1/auth/signout`.
 */
class SeptenaAuthClient(
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    suspend fun startDevice(clientName: String): DeviceCode {
        val body = obj("clientName" to JsonValue.StringValue(clientName))
        val response = post("/v1/auth/device/start", body)
        if (response.statusCode != 200) throw AuthHttpException(response.statusCode, response.body)
        val json = parseObject(response.body)
        return DeviceCode(
            code = json["code"].stringValue() ?: error("Device start response is missing code"),
            pollSecret = json["pollSecret"].stringValue() ?: error("Device start response is missing pollSecret"),
            expiresInSeconds = json["expiresIn"].longValue() ?: 600L,
            intervalSeconds = json["interval"].longValue() ?: 3L,
        )
    }

    suspend fun pollDevice(device: DeviceCode): DevicePollResult {
        val body = obj(
            "code" to JsonValue.StringValue(device.code),
            "pollSecret" to JsonValue.StringValue(device.pollSecret),
        )
        val response = post("/v1/auth/device/poll", body)
        return when (response.statusCode) {
            200 -> DevicePollResult.Approved(parseSession(response.body))
            202 -> DevicePollResult.Pending
            410 -> DevicePollResult.Expired
            else -> throw AuthHttpException(response.statusCode, response.body)
        }
    }

    /** Null when the refresh token is no longer valid (the user must sign in again). Throws on network errors. */
    suspend fun refresh(refreshToken: String): SessionTokens? {
        val response = post("/v1/auth/refresh", obj("refreshToken" to JsonValue.StringValue(refreshToken)))
        return when (response.statusCode) {
            200 -> parseSession(response.body)
            401 -> null
            else -> throw AuthHttpException(response.statusCode, response.body)
        }
    }

    suspend fun signOut(refreshToken: String) {
        post("/v1/auth/signout", obj("refreshToken" to JsonValue.StringValue(refreshToken)))
    }

    private suspend fun post(path: String, body: JsonValue.ObjectValue): HttpResponse =
        JsonHttp.send(baseUrl, path, "POST", body.canonicalJson(), clientVersion)

    private fun parseSession(body: String): SessionTokens {
        val json = parseObject(body)
        return SessionTokens(
            accessToken = json["accessToken"].stringValue() ?: error("Session is missing accessToken"),
            refreshToken = json["refreshToken"].stringValue() ?: error("Session is missing refreshToken"),
            expiresInSeconds = json["expiresIn"].longValue() ?: 3600L,
            userId = json["userId"].stringValue() ?: error("Session is missing userId"),
        )
    }

    private fun obj(vararg fields: Pair<String, JsonValue>) = JsonValue.ObjectValue(mapOf(*fields))

    private fun parseObject(body: String): JsonValue.ObjectValue =
        JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")

    private fun JsonValue?.longValue(): Long? = when (this) {
        is JsonValue.IntegerValue -> value
        is JsonValue.DecimalValue -> value.toLong()
        else -> null
    }
}
