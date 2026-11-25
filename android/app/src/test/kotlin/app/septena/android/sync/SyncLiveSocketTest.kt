package app.septena.android.sync

import app.septena.transport.LiveSocketOutcome
import app.septena.transport.SyncCredentials
import app.septena.transport.SyncLiveSocket
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

class SyncLiveSocketTest {

    @Test
    fun parseRevNudgeHandlesValidAndIgnoredPayloads() {
        assertEquals(42L, SyncLiveSocket.parseRevNudge("""{"rev":42}"""))
        assertEquals(0L, SyncLiveSocket.parseRevNudge("""{"rev": 0}"""))
        assertNull(SyncLiveSocket.parseRevNudge("pong"))
        assertNull(SyncLiveSocket.parseRevNudge(""))
        assertNull(SyncLiveSocket.parseRevNudge("{}"))
        assertNull(SyncLiveSocket.parseRevNudge("""{"rev":-1}"""))
        assertNull(SyncLiveSocket.parseRevNudge("not-json"))
    }

    @Test
    fun connectsReceivesRevNudgeRepliesToPingAndClosesCleanly() {
        val receivedRevs = CopyOnWriteArrayList<Long>()
        val sawPong = AtomicBoolean(false)
        val sawAuthHeader = AtomicBoolean(false)
        val sawClientHeader = AtomicBoolean(false)

        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { server ->
            val serverThread = thread(isDaemon = true) {
                server.accept().use { client ->
                    val input = BufferedInputStream(client.getInputStream())
                    val output = client.getOutputStream()
                    val (requestLine, headers) = readHttpRequest(input)
                    assertTrue(requestLine.startsWith("GET /v1/sync/ws HTTP/1.1"))
                    sawAuthHeader.set(headers["authorization"] == "Bearer tok-1")
                    sawClientHeader.set(headers["x-septena-client"] == "android 0.9.0")
                    val secKey = headers["sec-websocket-key"]!!
                    writeUpgrade101(output, secKey)

                    // Send a heartbeat text frame ("pong") that should be ignored.
                    writeServerFrame(output, 0x1, "pong".toByteArray(StandardCharsets.UTF_8))
                    // Send a rev nudge.
                    writeServerFrame(output, 0x1, """{"rev":42}""".toByteArray(StandardCharsets.UTF_8))
                    // Send a protocol Ping frame and verify client replies with masked Pong.
                    writeServerFrame(output, 0x9, "hi".toByteArray(StandardCharsets.UTF_8))
                    val (opcode, payload) = readClientMaskedFrame(input)
                    if (opcode == 0xA && String(payload, StandardCharsets.UTF_8) == "hi") {
                        sawPong.set(true)
                    }
                    // Send a Close frame.
                    writeServerFrame(output, 0x8, ByteArray(0))
                }
            }

            val creds = FakeCredentials(token = "tok-1")
            val socket = SyncLiveSocket(
                credentials = creds,
                clientVersion = "0.9.0",
                baseUrl = "http://127.0.0.1:${server.localPort}",
                pingIntervalMs = 60_000L,
                readTimeoutMs = 5_000,
            )
            var connected = false
            val outcome = runBlocking {
                socket.connectAndListen(
                    onConnected = { connected = true },
                    onRevNudge = { receivedRevs += it },
                )
            }
            serverThread.join(3_000)

            assertEquals(LiveSocketOutcome.Closed, outcome)
            assertTrue(connected)
            assertTrue(sawAuthHeader.get())
            assertTrue(sawClientHeader.get())
            assertTrue(sawPong.get())
            assertEquals(listOf(42L), receivedRevs)
        }
    }

    @Test
    fun refreshesOnceOnUnauthorizedAndConnects() {
        val attempts = AtomicInteger(0)
        val receivedRevs = CopyOnWriteArrayList<Long>()

        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { server ->
            val serverThread = thread(isDaemon = true) {
                repeat(2) {
                    server.accept().use { client ->
                        val input = BufferedInputStream(client.getInputStream())
                        val output = client.getOutputStream()
                        val (_, headers) = readHttpRequest(input)
                        val count = attempts.incrementAndGet()
                        if (count == 1) {
                            output.write("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                            output.flush()
                        } else {
                            assertEquals("Bearer tok-2", headers["authorization"])
                            writeUpgrade101(output, headers["sec-websocket-key"]!!)
                            writeServerFrame(output, 0x1, """{"rev":99}""".toByteArray(StandardCharsets.UTF_8))
                            writeServerFrame(output, 0x8, ByteArray(0))
                        }
                    }
                }
            }

            val creds = FakeCredentials(token = "tok-1", refreshedToken = "tok-2")
            val socket = SyncLiveSocket(
                credentials = creds,
                clientVersion = "0.9.0",
                baseUrl = "http://127.0.0.1:${server.localPort}",
                pingIntervalMs = 60_000L,
                readTimeoutMs = 5_000,
            )
            val outcome = runBlocking {
                socket.connectAndListen(onConnected = {}, onRevNudge = { receivedRevs += it })
            }
            serverThread.join(3_000)

            assertEquals(LiveSocketOutcome.Closed, outcome)
            assertEquals(2, attempts.get())
            assertEquals(1, creds.refreshCount.get())
            assertEquals(listOf(99L), receivedRevs)
        }
    }

    @Test
    fun returnsLiveSyncBlockedOnHttp402() {
        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { server ->
            val serverThread = thread(isDaemon = true) {
                server.accept().use { client ->
                    val input = BufferedInputStream(client.getInputStream())
                    readHttpRequest(input)
                    val response = "HTTP/1.1 402 Payment Required\r\nContent-Length: 31\r\n\r\n{\"error\":\"live_sync_not_in_plan\"}"
                    client.getOutputStream().write(response.toByteArray(StandardCharsets.US_ASCII))
                    client.getOutputStream().flush()
                }
            }

            val socket = SyncLiveSocket(
                credentials = FakeCredentials(token = "tok-1"),
                clientVersion = "0.9.0",
                baseUrl = "http://127.0.0.1:${server.localPort}",
                pingIntervalMs = 60_000L,
                readTimeoutMs = 5_000,
            )
            val outcome = runBlocking {
                socket.connectAndListen(onConnected = {}, onRevNudge = {})
            }
            serverThread.join(3_000)

            assertEquals(LiveSocketOutcome.LiveSyncBlocked, outcome)
        }
    }

    private class FakeCredentials(
        private var token: String?,
        private val refreshedToken: String? = null,
    ) : SyncCredentials {
        val refreshCount = AtomicInteger(0)
        override suspend fun accessToken(): String? = token
        override suspend fun refreshAfterUnauthorized(): String? {
            refreshCount.incrementAndGet()
            token = refreshedToken
            return refreshedToken
        }
    }

    private fun readHttpRequest(input: InputStream): Pair<String, Map<String, String>> {
        val requestLine = readLine(input)
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = readLine(input)
            if (line.isEmpty()) break
            val colon = line.indexOf(':')
            if (colon > 0) {
                headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
            }
        }
        return requestLine to headers
    }

    private fun readLine(input: InputStream): String {
        val buf = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1 || b == '\n'.code) break
            if (b != '\r'.code) buf.write(b)
        }
        return buf.toString(StandardCharsets.US_ASCII.name())
    }

    private fun writeUpgrade101(output: OutputStream, secKey: String) {
        val digest = MessageDigest.getInstance("SHA-1")
            .digest((secKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray(StandardCharsets.US_ASCII))
        val accept = Base64.getEncoder().encodeToString(digest)
        val response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: $accept\r\n\r\n"
        output.write(response.toByteArray(StandardCharsets.US_ASCII))
        output.flush()
    }

    private fun writeServerFrame(output: OutputStream, opcode: Int, payload: ByteArray) {
        output.write(0x80 or (opcode and 0x0F))
        output.write(payload.size and 0x7F)
        output.write(payload)
        output.flush()
    }

    private fun readClientMaskedFrame(input: InputStream): Pair<Int, ByteArray> {
        val b0 = input.read()
        val b1 = input.read()
        val opcode = b0 and 0x0F
        val masked = (b1 and 0x80) != 0
        assertTrue("Client WebSocket frames must be masked", masked)
        val len = b1 and 0x7F
        val mask = ByteArray(4) { input.read().toByte() }
        val payload = ByteArray(len) { i -> (input.read() xor (mask[i and 3].toInt() and 0xFF)).toByte() }
        return opcode to payload
    }
}
