package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.longValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

sealed interface LiveSocketOutcome {
    /** The server closed the socket cleanly or the caller cancelled it. */
    data object Closed : LiveSocketOutcome

    /** Credentials are missing or HTTP 401 persisted after a single token refresh. */
    data object NeedsSignIn : LiveSocketOutcome

    /** HTTP 402 (`live_sync_not_in_plan` / `device_not_syncing`): fall back to polling. */
    data object LiveSyncBlocked : LiveSocketOutcome

    /** Transient network, handshake, or protocol failure; caller may retry with backoff. */
    data class Failed(val message: String) : LiveSocketOutcome
}

/**
 * Lightweight RFC 6455 WebSocket client for `/v1/sync/ws`, carrying `{ "rev": N }`
 * nudges only (docs/SEPTASK_BACKEND.md §6.3) with zero third-party dependencies.
 *
 * Uses the same Bearer auth + single-401 refresh contract as [UrlConnectionSyncTransport]
 * and the `"ping"` / `"pong"` text heartbeat that Cloudflare Durable Objects auto-respond
 * to without waking the DO from hibernation (matching Apple `TaskSyncEngine.swift`).
 */
class SyncLiveSocket(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
    private val pingIntervalMs: Long = DEFAULT_PING_INTERVAL_MS,
    private val readTimeoutMs: Int = DEFAULT_READ_TIMEOUT_MS,
    private val connectTimeoutMs: Int = DEFAULT_CONNECT_TIMEOUT_MS,
) {
    private val random = SecureRandom()

    suspend fun connectAndListen(
        onConnected: () -> Unit,
        onRevNudge: (Long) -> Unit,
    ): LiveSocketOutcome = withContext(Dispatchers.IO) {
        val firstToken = credentials.accessToken() ?: return@withContext LiveSocketOutcome.NeedsSignIn
        val attempt = try {
            openAndHandshake(firstToken)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return@withContext LiveSocketOutcome.Failed(error.message ?: error.javaClass.simpleName)
        }

        val session = when (attempt) {
            is HandshakeAttempt.Connected -> attempt
            HandshakeAttempt.Unauthorized -> {
                val renewed = credentials.refreshAfterUnauthorized()
                    ?: return@withContext LiveSocketOutcome.NeedsSignIn
                val retry = try {
                    openAndHandshake(renewed)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    return@withContext LiveSocketOutcome.Failed(error.message ?: error.javaClass.simpleName)
                }
                when (retry) {
                    is HandshakeAttempt.Connected -> retry
                    HandshakeAttempt.Unauthorized -> return@withContext LiveSocketOutcome.NeedsSignIn
                    HandshakeAttempt.PaymentRequired -> return@withContext LiveSocketOutcome.LiveSyncBlocked
                    is HandshakeAttempt.Failed -> return@withContext LiveSocketOutcome.Failed(retry.message)
                }
            }
            HandshakeAttempt.PaymentRequired -> return@withContext LiveSocketOutcome.LiveSyncBlocked
            is HandshakeAttempt.Failed -> return@withContext LiveSocketOutcome.Failed(attempt.message)
        }

        val socket = session.socket
        val input = session.input
        val output = session.output
        val writeLock = Any()

        // Closing the socket immediately on coroutine cancellation unblocks `input.read()`.
        val cancelHandle = coroutineContext.job.invokeOnCompletion {
            runCatching { socket.close() }
        }

        try {
            onConnected()
            coroutineScope {
                val keepAliveJob = launch {
                    while (isActive) {
                        delay(pingIntervalMs)
                        try {
                            synchronized(writeLock) {
                                writeMaskedFrame(output, OPCODE_TEXT, PING_PAYLOAD)
                            }
                        } catch (_: IOException) {
                            runCatching { socket.close() }
                            break
                        }
                    }
                }
                try {
                    readLoop(input, output, writeLock, onRevNudge)
                } finally {
                    keepAliveJob.cancel()
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            if (!isActive) LiveSocketOutcome.Closed
            else LiveSocketOutcome.Failed(error.message ?: error.javaClass.simpleName)
        } finally {
            cancelHandle.dispose()
            runCatching { socket.close() }
        }
    }

    private fun openAndHandshake(token: String): HandshakeAttempt {
        val uri = URI(baseUrl.trimEnd('/') + WS_PATH)
        val secure = when (uri.scheme?.lowercase()) {
            "https", "wss" -> true
            "http", "ws" -> false
            else -> throw IOException("Unsupported sync WebSocket scheme: ${uri.scheme}")
        }
        val host = uri.host ?: throw IOException("Missing host in $baseUrl")
        val port = if (uri.port > 0) uri.port else if (secure) 443 else 80
        val defaultPort = if (secure) 443 else 80
        val hostHeader = if (port == defaultPort) host else "$host:$port"
        val requestPath = buildString {
            append(uri.rawPath?.takeIf(String::isNotEmpty) ?: WS_PATH)
            uri.rawQuery?.takeIf(String::isNotEmpty)?.let { append('?').append(it) }
        }

        val socket = openSocket(host, port, secure)
        var keepOpen = false
        try {
            socket.soTimeout = connectTimeoutMs
            val keyBytes = ByteArray(16).also(random::nextBytes)
            val secKey = Base64.getEncoder().encodeToString(keyBytes)
            val output = socket.getOutputStream()
            val request = buildString {
                append("GET ").append(requestPath).append(" HTTP/1.1\r\n")
                append("Host: ").append(hostHeader).append("\r\n")
                append("Upgrade: websocket\r\n")
                append("Connection: Upgrade\r\n")
                append("Sec-WebSocket-Key: ").append(secKey).append("\r\n")
                append("Sec-WebSocket-Version: 13\r\n")
                append("Authorization: Bearer ").append(token).append("\r\n")
                append("X-Septena-Client: android ").append(clientVersion).append("\r\n")
                append("\r\n")
            }
            output.write(request.toByteArray(StandardCharsets.US_ASCII))
            output.flush()

            val input = BufferedInputStream(socket.getInputStream())
            val statusLine = readAsciiLine(input)
                ?: return HandshakeAttempt.Failed("Unexpected EOF during WebSocket handshake")
            val statusCode = parseStatusCode(statusLine)
                ?: return HandshakeAttempt.Failed("Malformed HTTP status: $statusLine")

            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = readAsciiLine(input) ?: break
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) {
                    val name = line.substring(0, colon).trim().lowercase()
                    val value = line.substring(colon + 1).trim()
                    headers[name] = value
                }
            }

            return when (statusCode) {
                101 -> {
                    val expectedAccept = computeWebSocketAccept(secKey)
                    val actualAccept = headers["sec-websocket-accept"]
                    if (actualAccept != expectedAccept) {
                        HandshakeAttempt.Failed("Invalid Sec-WebSocket-Accept header")
                    } else {
                        socket.soTimeout = readTimeoutMs
                        keepOpen = true
                        HandshakeAttempt.Connected(socket, input, output)
                    }
                }
                401 -> HandshakeAttempt.Unauthorized
                402 -> HandshakeAttempt.PaymentRequired
                else -> HandshakeAttempt.Failed("WebSocket upgrade failed with HTTP $statusCode")
            }
        } finally {
            if (!keepOpen) runCatching { socket.close() }
        }
    }

    private fun openSocket(host: String, port: Int, secure: Boolean): Socket {
        val address = InetSocketAddress(host, port)
        return if (secure) {
            val ssl = SSLSocketFactory.getDefault().createSocket() as SSLSocket
            val params = ssl.sslParameters
            params.endpointIdentificationAlgorithm = "HTTPS"
            if (!isIpLiteral(host)) {
                params.serverNames = listOf(SNIHostName(host))
            }
            ssl.sslParameters = params
            ssl.connect(address, connectTimeoutMs)
            ssl.soTimeout = connectTimeoutMs
            ssl.startHandshake()
            ssl
        } else {
            Socket().apply {
                connect(address, connectTimeoutMs)
            }
        }
    }

    private fun readLoop(
        input: InputStream,
        output: OutputStream,
        writeLock: Any,
        onRevNudge: (Long) -> Unit,
    ): LiveSocketOutcome {
        var textAccumulator: ByteArrayOutputStream? = null
        while (true) {
            val b0 = input.read()
            if (b0 == -1) return LiveSocketOutcome.Closed
            val b1 = input.read()
            if (b1 == -1) return LiveSocketOutcome.Closed

            val fin = (b0 and 0x80) != 0
            val opcode = b0 and 0x0F
            val masked = (b1 and 0x80) != 0
            val payloadLen = readPayloadLength(input, b1 and 0x7F)
            if (payloadLen < 0 || payloadLen > MAX_FRAME_BYTES) {
                throw IOException("Invalid WebSocket frame length: $payloadLen")
            }

            val maskKey = if (masked) readExact(input, 4) else null
            val payload = if (payloadLen == 0) ByteArray(0) else readExact(input, payloadLen)
            if (maskKey != null) {
                for (i in payload.indices) {
                    payload[i] = (payload[i].toInt() xor maskKey[i and 3].toInt()).toByte()
                }
            }

            when (opcode) {
                OPCODE_CLOSE -> {
                    runCatching {
                        synchronized(writeLock) {
                            writeMaskedFrame(output, OPCODE_CLOSE, ByteArray(0))
                        }
                    }
                    return LiveSocketOutcome.Closed
                }
                OPCODE_PING -> {
                    synchronized(writeLock) {
                        writeMaskedFrame(output, OPCODE_PONG, payload)
                    }
                }
                OPCODE_PONG -> Unit
                OPCODE_TEXT -> {
                    if (fin) {
                        textAccumulator = null
                        dispatchText(String(payload, StandardCharsets.UTF_8), onRevNudge)
                    } else {
                        textAccumulator = ByteArrayOutputStream().apply { write(payload) }
                    }
                }
                OPCODE_CONTINUATION -> {
                    val acc = textAccumulator
                    if (acc != null) {
                        if (acc.size() + payload.size > MAX_FRAME_BYTES) {
                            throw IOException("Fragmented WebSocket message too large")
                        }
                        acc.write(payload)
                        if (fin) {
                            textAccumulator = null
                            dispatchText(acc.toString(StandardCharsets.UTF_8.name()), onRevNudge)
                        }
                    }
                }
                OPCODE_BINARY -> Unit
                else -> throw IOException("Unsupported WebSocket opcode: $opcode")
            }
        }
    }

    private fun dispatchText(text: String, onRevNudge: (Long) -> Unit) {
        if (text == "pong") return
        val rev = parseRevNudge(text) ?: return
        onRevNudge(rev)
    }

    private fun writeMaskedFrame(output: OutputStream, opcode: Int, payload: ByteArray) {
        val mask = ByteArray(4).also(random::nextBytes)
        output.write(0x80 or (opcode and 0x0F))
        val len = payload.size
        when {
            len <= 125 -> output.write(0x80 or len)
            len <= 65_535 -> {
                output.write(0x80 or 126)
                output.write((len ushr 8) and 0xFF)
                output.write(len and 0xFF)
            }
            else -> {
                output.write(0x80 or 127)
                val lenLong = len.toLong()
                for (shift in 56 downTo 0 step 8) {
                    output.write(((lenLong ushr shift) and 0xFFL).toInt())
                }
            }
        }
        output.write(mask)
        if (payload.isNotEmpty()) {
            val masked = ByteArray(payload.size)
            for (i in payload.indices) {
                masked[i] = (payload[i].toInt() xor mask[i and 3].toInt()).toByte()
            }
            output.write(masked)
        }
        output.flush()
    }

    private fun readPayloadLength(input: InputStream, initial: Int): Int = when {
        initial <= 125 -> initial
        initial == 126 -> {
            val bytes = readExact(input, 2)
            ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
        }
        else -> {
            val bytes = readExact(input, 8)
            var value = 0L
            for (b in bytes) value = (value shl 8) or (b.toLong() and 0xFFL)
            if (value > MAX_FRAME_BYTES) -1 else value.toInt()
        }
    }

    private fun readExact(input: InputStream, count: Int): ByteArray {
        val out = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = input.read(out, offset, count - offset)
            if (read == -1) throw EOFException("Unexpected EOF reading WebSocket frame")
            offset += read
        }
        return out
    }

    private fun readAsciiLine(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var sawAny = false
        while (true) {
            val b = input.read()
            if (b == -1) return if (sawAny) buffer.toString(StandardCharsets.US_ASCII.name()) else null
            sawAny = true
            if (b == '\n'.code) {
                val bytes = buffer.toByteArray()
                val end = if (bytes.isNotEmpty() && bytes[bytes.size - 1] == '\r'.code.toByte()) {
                    bytes.size - 1
                } else {
                    bytes.size
                }
                return String(bytes, 0, end, StandardCharsets.US_ASCII)
            }
            if (buffer.size() >= MAX_HEADER_LINE_BYTES) {
                throw IOException("HTTP response header line too long")
            }
            buffer.write(b)
        }
    }

    private fun parseStatusCode(statusLine: String): Int? {
        val parts = statusLine.split(' ')
        if (parts.size < 2 || !parts[0].startsWith("HTTP/")) return null
        return parts[1].toIntOrNull()
    }

    private sealed interface HandshakeAttempt {
        data class Connected(
            val socket: Socket,
            val input: BufferedInputStream,
            val output: OutputStream,
        ) : HandshakeAttempt

        data object Unauthorized : HandshakeAttempt
        data object PaymentRequired : HandshakeAttempt
        data class Failed(val message: String) : HandshakeAttempt
    }

    companion object {
        private const val WS_PATH = "/v1/sync/ws"
        private const val WS_MAGIC_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        private const val OPCODE_CONTINUATION = 0x0
        private const val OPCODE_TEXT = 0x1
        private const val OPCODE_BINARY = 0x2
        private const val OPCODE_CLOSE = 0x8
        private const val OPCODE_PING = 0x9
        private const val OPCODE_PONG = 0xA
        private const val MAX_FRAME_BYTES = 65_536
        private const val MAX_HEADER_LINE_BYTES = 8_192
        private val PING_PAYLOAD = "ping".toByteArray(StandardCharsets.UTF_8)

        const val DEFAULT_PING_INTERVAL_MS = 30_000L
        const val DEFAULT_READ_TIMEOUT_MS = 75_000
        const val DEFAULT_CONNECT_TIMEOUT_MS = 15_000

        /** Parses a server `{ "rev": 123 }` nudge frame; returns null for heartbeats or non-nudge text. */
        fun parseRevNudge(text: String): Long? {
            if (text.isBlank() || text == "pong") return null
            val parsed = runCatching { JsonValue.parse(text) }.getOrNull() as? JsonValue.ObjectValue ?: return null
            return parsed["rev"].longValue()?.takeIf { it >= 0L }
        }

        internal fun computeWebSocketAccept(secKey: String): String {
            val digest = MessageDigest.getInstance("SHA-1")
                .digest((secKey + WS_MAGIC_GUID).toByteArray(StandardCharsets.US_ASCII))
            return Base64.getEncoder().encodeToString(digest)
        }

        private fun isIpLiteral(host: String): Boolean {
            if (host.contains(':')) return true
            return host.split('.').let { parts ->
                parts.size == 4 && parts.all { it.toIntOrNull() in 0..255 }
            }
        }
    }
}
