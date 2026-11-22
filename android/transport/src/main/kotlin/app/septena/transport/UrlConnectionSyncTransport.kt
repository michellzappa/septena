package app.septena.transport

import app.septena.core.SyncOperation
import app.septena.core.SyncPullPage
import app.septena.core.SyncPushResponse
import app.septena.core.SyncTransport
import app.septena.core.SyncWireCodec
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/** Credentials are supplied by the app layer, where refresh tokens live in the Android Keystore. */
interface SyncCredentials {
    suspend fun accessToken(): String?

    /** Must serialize single-use refreshes and return the replacement access token. */
    suspend fun refreshAfterUnauthorized(): String?
}

class SyncHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena sync returned HTTP $statusCode",
)

class SyncAuthenticationException : IOException("Sign in to sync this device")

/** HTTP adapter shared by Android and future JVM clients; endpoint payloads stay in `SyncWireCodec`. */
class UrlConnectionSyncTransport(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = DEFAULT_BASE_URL,
    private val executor: ExecutorService = NETWORK_EXECUTOR,
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
        if (final.statusCode !in 200..299) throw SyncHttpException(final.statusCode, final.body)
        return final.body
    }

    private suspend fun perform(path: String, method: String, body: String?, token: String): HttpResponse =
        suspendCoroutine { continuation ->
            executor.execute {
                try {
                    continuation.resume(execute(path, method, body, token))
                } catch (error: Throwable) {
                    continuation.resumeWithException(error)
                }
            }
        }

    private fun execute(path: String, method: String, body: String?, token: String): HttpResponse {
        val connection = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("X-Septena-Client", "android $clientVersion")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { output ->
                    output.write(body.toByteArray(StandardCharsets.UTF_8))
                }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val responseBody = stream?.use { it.readBytes().toString(StandardCharsets.UTF_8) }.orEmpty()
            return HttpResponse(status, responseBody)
        } finally {
            connection.disconnect()
        }
    }

    private fun Boolean.flag(): Int = if (this) 1 else 0

    private data class HttpResponse(val statusCode: Int, val body: String)

    companion object {
        const val DEFAULT_BASE_URL = "https://api.septena.app"
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
        private val NETWORK_EXECUTOR = Executors.newFixedThreadPool(2) { runnable ->
            Thread(runnable, "septena-sync-http").apply { isDaemon = true }
        }
    }
}
