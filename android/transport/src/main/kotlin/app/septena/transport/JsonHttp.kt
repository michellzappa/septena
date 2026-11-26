package app.septena.transport

import java.io.File
import java.io.IOException
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

/** One blocking HTTP request on a background executor. Shared by the sync, auth and task backend clients. */
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
        headers: Map<String, String> = emptyMap(),
    ): HttpResponse = perform(pool) { onOpened ->
        execute(baseUrl, path, method, clientVersion, bearer, accept = "application/json", onOpened, headers) { connection ->
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { output ->
                    output.write(body.toByteArray(StandardCharsets.UTF_8))
                }
            }
            val status = connection.responseCode
            HttpResponse(status, connection.readBody(status))
        }
    }

    /**
     * One request that streams a file up ([upload], sent with [uploadType]) or a
     * successful response down into [download]. The download lands in a
     * temporary file first and replaces [download] only when complete. A failed
     * request returns its body as text, like [send].
     */
    suspend fun transfer(
        baseUrl: String,
        path: String,
        method: String,
        clientVersion: String,
        bearer: String?,
        upload: File? = null,
        uploadType: String? = null,
        download: File? = null,
        pool: ExecutorService = executor,
    ): HttpResponse = perform(pool) { onOpened ->
        execute(baseUrl, path, method, clientVersion, bearer, accept = "*/*", onOpened) { connection ->
            if (upload != null) {
                val length = upload.length()
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(length)
                connection.setRequestProperty("Content-Type", uploadType ?: "application/octet-stream")
                upload.inputStream().use { input -> connection.outputStream.use { input.copyTo(it) } }
            }
            val status = connection.responseCode
            if (download != null && status in 200..299) {
                download.parentFile?.mkdirs()
                val partial = File(download.parentFile, download.name + ".part")
                connection.inputStream.use { input -> partial.outputStream().use { input.copyTo(it) } }
                if (!partial.renameTo(download)) {
                    partial.delete()
                    throw IOException("Could not write ${download.name}")
                }
                HttpResponse(status, "")
            } else {
                HttpResponse(status, connection.readBody(status))
            }
        }
    }

    private suspend fun perform(
        pool: ExecutorService,
        work: ((HttpURLConnection) -> Unit) -> HttpResponse,
    ): HttpResponse = suspendCancellableCoroutine { continuation ->
        val activeConnection = AtomicReference<HttpURLConnection?>(null)
        val request = AtomicReference<Future<*>?>(null)
        val future = pool.submit {
            try {
                val response = work { connection ->
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
        clientVersion: String,
        bearer: String?,
        accept: String,
        onConnectionOpened: (HttpURLConnection) -> Unit,
        headers: Map<String, String> = emptyMap(),
        exchange: (HttpURLConnection) -> HttpResponse,
    ): HttpResponse {
        val connection = URL(baseUrl.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            onConnectionOpened(connection)
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.setRequestProperty("Accept", accept)
            connection.setRequestProperty("X-Septena-Client", "android $clientVersion")
            if (bearer != null) connection.setRequestProperty("Authorization", "Bearer $bearer")
            for ((name, value) in headers) connection.setRequestProperty(name, value)
            return exchange(connection)
        } finally {
            connection.disconnect()
        }
    }

    private fun HttpURLConnection.readBody(status: Int): String {
        val stream = if (status in 200..299) inputStream else errorStream
        return stream?.use { it.readBytes().toString(StandardCharsets.UTF_8) }.orEmpty()
    }
}
