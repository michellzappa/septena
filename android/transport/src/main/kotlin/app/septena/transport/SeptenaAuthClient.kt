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

/** POST /v1/auth/email/start: what the server answered (#169). */
sealed interface EmailStartResult {
    /** A code is on its way. The server answers this for a known and an unknown address alike. */
    data class Sent(val expiresInSeconds: Long, val codeLength: Int) : EmailStartResult
    /** 400: the server does not accept the address. */
    data object InvalidEmail : EmailStartResult
    /** 429: too many codes asked for. */
    data class RateLimited(val retryAfterSeconds: Long?) : EmailStartResult
    /** 503: email sign-in is off on this server, or the email did not go out. */
    data class Unavailable(val error: String) : EmailStartResult
}

/** POST /v1/auth/email/verify: what the server answered (#169). */
sealed interface EmailVerifyResult {
    /** The same session JSON as a device approval. A new address created an account. */
    data class SignedIn(val tokens: SessionTokens) : EmailVerifyResult
    /** 401: a wrong code; [attemptsLeft] more tries on this code. */
    data class WrongCode(val attemptsLeft: Int) : EmailVerifyResult
    /** 410: the code expired, or the server knows no code for the address. */
    data object Expired : EmailVerifyResult
    /** 429: too many wrong codes. The user asks for a new one. */
    data object TooManyAttempts : EmailVerifyResult
}

class AuthHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena sign-in returned HTTP $statusCode",
)

/**
 * Sign-in by device approval (ADR 0016, issue #170), by an email code (#169) and session refresh.
 * Routes: `/v1/auth/methods`, `/v1/auth/device/start`, `/v1/auth/device/poll`, `/v1/auth/email/start`,
 * `/v1/auth/email/verify`, `/v1/auth/refresh`, `/v1/auth/signout`.
 */
class SeptenaAuthClient(
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    /**
     * The sign-in method ids this server has turned on (ADR 0047). Throws on any answer that is not a
     * well-formed list: the caller then offers device approval only.
     */
    suspend fun signInMethods(): Set<String> {
        val response = JsonHttp.send(baseUrl, "/v1/auth/methods", "GET", null, clientVersion)
        if (response.statusCode != 200) throw AuthHttpException(response.statusCode, response.body)
        val methods = parseObject(response.body)["methods"] as? JsonValue.ArrayValue
            ?: error("Methods response is missing methods")
        return methods.values.map { entry ->
            val id = (entry as? JsonValue.ObjectValue)?.get("id").stringValue()
                ?: error("Methods response has a method without an id")
            require(METHOD_ID.matches(id)) { "Methods response has a bad method id" }
            id
        }.toSet()
    }

    suspend fun startEmail(email: String): EmailStartResult {
        val response = post("/v1/auth/email/start", obj("email" to JsonValue.StringValue(email)))
        return when (response.statusCode) {
            202 -> {
                val json = parseObject(response.body)
                require(json["status"].stringValue() == "sent") { "Email start response is not sent" }
                val length = json["codeLength"].longValue()?.toInt() ?: error("Email start response is missing codeLength")
                require(length in 4..12) { "Email start response has a bad codeLength" }
                EmailStartResult.Sent(
                    expiresInSeconds = json["expiresInSeconds"].longValue()?.takeIf { it > 0 }
                        ?: error("Email start response is missing expiresInSeconds"),
                    codeLength = length,
                )
            }
            400 -> EmailStartResult.InvalidEmail
            429 -> EmailStartResult.RateLimited(errorBody(response.body)?.get("retryAfterSeconds").longValue())
            503 -> EmailStartResult.Unavailable(errorBody(response.body)?.get("error").stringValue() ?: "unavailable")
            else -> throw AuthHttpException(response.statusCode, response.body)
        }
    }

    suspend fun verifyEmail(email: String, code: String): EmailVerifyResult {
        val body = obj("email" to JsonValue.StringValue(email), "code" to JsonValue.StringValue(code))
        val response = post("/v1/auth/email/verify", body)
        return when (response.statusCode) {
            200 -> EmailVerifyResult.SignedIn(parseSession(response.body))
            401 -> {
                val failure = errorBody(response.body)
                if (failure?.get("error").stringValue() != "invalid_code") throw AuthHttpException(401, response.body)
                val left = failure?.get("attemptsLeft").longValue()?.toInt() ?: error("Invalid code response is missing attemptsLeft")
                EmailVerifyResult.WrongCode(left.coerceAtLeast(0))
            }
            410 -> EmailVerifyResult.Expired
            429 -> EmailVerifyResult.TooManyAttempts
            else -> throw AuthHttpException(response.statusCode, response.body)
        }
    }

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

    /** The JSON object of an error answer; null when the body is not one (a proxy page). */
    private fun errorBody(body: String): JsonValue.ObjectValue? = runCatching { parseObject(body) }.getOrNull()

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

    private companion object {
        /** A registry method id (gen-registries.mjs checks `^[a-z]+$`). */
        val METHOD_ID = Regex("^[a-z]+$")
    }
}
