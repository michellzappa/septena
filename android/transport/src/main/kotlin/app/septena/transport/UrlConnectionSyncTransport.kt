package app.septena.transport

import app.septena.core.SyncOperation
import app.septena.core.SyncHttpFailure
import app.septena.core.SyncPullPage
import app.septena.core.SyncPushResponse
import app.septena.core.SyncTransport
import app.septena.core.SyncWireCodec
import java.io.IOException
import java.net.HttpURLConnection
import java.util.concurrent.ExecutorService

/** Credentials are supplied by the app layer, where refresh tokens live in the Android Keystore. */
interface SyncCredentials {
    suspend fun accessToken(): String?

    /** Must serialize single-use refreshes and return the replacement access token. */
    suspend fun refreshAfterUnauthorized(): String?
}

class SyncHttpException(statusCode: Int, responseBody: String) : SyncHttpFailure(statusCode, responseBody)

class SyncAuthenticationException : IOException("Sign in to sync this device")

/** HTTP 402 from the sync routes: the account has no active sync subscription. */
class SyncSubscriptionRequiredException : IOException("Sync needs an active Septena subscription")

/** HTTP adapter shared by Android and future JVM clients; endpoint payloads stay in `SyncWireCodec`. */
class UrlConnectionSyncTransport(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = DEFAULT_BASE_URL,
    private val executor: ExecutorService = JsonHttp.executor,
) : SyncTransport {
    override suspend fun push(operations: List<SyncOperation>): SyncPushResponse {
        val body = SyncWireCodec.encodePushBody(operations)
        return SyncWireCodec.decodePushResponse(request("/v1/sync/push", "POST", body))
    }

    override suspend fun pull(
        since: Long,
        limit: Int,
        includeSettings: Boolean,
        includeChecklists: Boolean,
        includeTags: Boolean,
    ): SyncPullPage {
        require(since >= 0) { "Sync cursor cannot be negative" }
        require(limit > 0) { "Sync page limit must be positive" }
        val path = "/v1/sync/pull?" + listOf(
            "since=$since",
            "limit=$limit",
            "settings=${includeSettings.flag()}",
            "checklists=${includeChecklists.flag()}",
            "tags=${includeTags.flag()}",
        ).joinToString("&")
        return SyncWireCodec.decodePullPage(request(path, "GET", body = null))
    }

    private suspend fun request(path: String, method: String, body: String?): String {
        val firstToken = credentials.accessToken() ?: throw SyncAuthenticationException()
        val first = perform(path, method, body, firstToken)
        val final = if (first.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            val renewed = credentials.refreshAfterUnauthorized() ?: throw SyncAuthenticationException()
            perform(path, method, body, renewed)
        } else {
            first
        }
        if (final.statusCode == HTTP_PAYMENT_REQUIRED) throw SyncSubscriptionRequiredException()
        if (final.statusCode !in 200..299) throw SyncHttpException(final.statusCode, final.body)
        return final.body
    }

    private suspend fun perform(path: String, method: String, body: String?, token: String): HttpResponse =
        JsonHttp.send(baseUrl, path, method, body, clientVersion, bearer = token, pool = executor)

    private fun Boolean.flag(): Int = if (this) 1 else 0

    companion object {
        const val DEFAULT_BASE_URL = JsonHttp.DEFAULT_BASE_URL
        private const val HTTP_PAYMENT_REQUIRED = 402
    }
}
