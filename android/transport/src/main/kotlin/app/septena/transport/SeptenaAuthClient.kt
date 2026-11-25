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
    /** The sign-in QR from the backend (`src/shadow/pairQr.ts`); null from a backend that does not send it. */
    val qr: SignInQr? = null,
) {
    /** The code as the backend's pairing page shows it: `ABCD-EFGH`. */
    val displayCode: String get() = if (code.length == 8) code.take(4) + "-" + code.drop(4) else code
}

/**
 * A QR code as the backend encodes it: [size] modules per side, [modules] row by row, `true` dark.
 * The backend owns the one QR encoder, so this app needs no QR library. The drawer adds the quiet zone.
 */
class SignInQr(val size: Int, val modules: BooleanArray) {
    fun isDark(row: Int, col: Int): Boolean = modules[row * size + col]

    companion object {
        /** Null unless the JSON is a well-formed QR matrix (21 to 177 modules per side, only `0` and `1`). */
        fun parse(json: JsonValue?): SignInQr? {
            val obj = json as? JsonValue.ObjectValue ?: return null
            val size = (obj["size"] as? JsonValue.IntegerValue)?.value?.toInt() ?: return null
            val text = obj["modules"].stringValue() ?: return null
            if (size !in 21..177 || (size - 17) % 4 != 0 || text.length != size * size) return null
            if (text.any { it != '0' && it != '1' }) return null
            return SignInQr(size, BooleanArray(text.length) { text[it] == '1' })
        }
    }
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
            qr = SignInQr.parse(json["qr"]),
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

    /**
     * Null when our server ended the session (the user must sign in again). Any other 401 (a proxy, a
     * captive portal) throws like a network error: it is not a sign-out.
     */
    suspend fun refresh(refreshToken: String): SessionTokens? {
        val response = post("/v1/auth/refresh", obj("refreshToken" to JsonValue.StringValue(refreshToken)))
        return when (response.statusCode) {
            200 -> parseSession(response.body)
            401 -> if (isInvalidGrant(response.body)) null else throw AuthHttpException(401, response.body)
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

    private fun isInvalidGrant(body: String): Boolean =
        runCatching { parseObject(body)["error"].stringValue() }.getOrNull() == "invalid_grant"

    private fun obj(vararg fields: Pair<String, JsonValue>) = JsonValue.ObjectValue(mapOf(*fields))

    private fun parseObject(body: String): JsonValue.ObjectValue =
        JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")

    private fun JsonValue?.longValue(): Long? = when (this) {
        is JsonValue.IntegerValue -> value
        is JsonValue.DecimalValue -> value.toLong()
        else -> null
    }
}
