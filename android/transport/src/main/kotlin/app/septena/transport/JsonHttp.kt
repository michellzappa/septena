package app.septena.transport

import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal data class HttpResponse(val statusCode: Int, val body: String)

/** One blocking JSON request on a background executor. Shared by the sync and auth clients. */
internal object JsonHttp {
    const val DEFAULT_BASE_URL = "https://api.septena.app"
    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 30_000

    val executor: ExecutorService = Executors.newFixedThreadPool(2) { runnable ->
        Thread(runnable, "septena-http").apply { isDaemon = true }
    }

    suspend fun send(
        baseUrl: String,
        path: String,
        method: String,
        body: String?,
        clientVersion: String,
        bearer: String? = null,
        pool: ExecutorService = executor,
    ): HttpResponse = suspendCancellableCoroutine { continuation ->
        val activeConnection = AtomicReference<HttpURLConnection?>(null)
        val request = AtomicReference<Future<*>?>(null)
        val future = pool.submit {
            try {
                val response = execute(
                    baseUrl,
                    path,
                    method,
                    body,
                    clientVersion,
                    bearer,
                ) { connection ->
                    activeConnection.set(connection)
                    if (!continuation.isActive) {
                        connection.disconnect()
                        throw java.util.concurrent.CancellationException("HTTP request was cancelled")
                    }
                }
                continuation.resume(response)
            } catch (error: Throwable) {
                continuation.resumeWithException(error)
            } finally {
                activeConnection.set(null)
            }
        }
        request.set(future)
        continuation.invokeOnCancellation {
            activeConnection.getAndSet(null)?.disconnect()
            request.getAndSet(null)?.cancel(true)
        }
    }

    private fun execute(
        baseUrl: String,
        path: String,
        method: String,
        body: String?,
        clientVersion: String,
        bearer: String?,
        onConnectionOpened: (HttpURLConnection) -> Unit,
    ): HttpResponse {
        val connection = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            onConnectionOpened(connection)
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("X-Septena-Client", "android $clientVersion")
            if (bearer != null) connection.setRequestProperty("Authorization", "Bearer $bearer")
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
}
