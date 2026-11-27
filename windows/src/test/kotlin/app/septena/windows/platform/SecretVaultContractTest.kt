package app.septena.windows.platform

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap

class SecretVaultContractTest {
    @Test fun missingSessionReturnsNull() {
        val sessions = AccountSessionVault(InMemorySecretVault())
        assertNull(sessions.read("account-a"))
    }

    @Test fun envelopeForAnotherAccountIsRejected() {
        val raw = InMemorySecretVault()
        raw.write("account-b", envelope("account-a", 0, byteArrayOf(1)))
        assertFailure("another account") { AccountSessionVault(raw).read("account-b") }
    }

    @Test fun corruptEnvelopeIsRejected() {
        val raw = InMemorySecretVault()
        raw.write("account-a", byteArrayOf(1, 2, 3))
        assertFailure("saved session") { AccountSessionVault(raw).read("account-a") }
    }

    @Test fun overlappingAccountsKeepTheirOwnSessions() {
        val sessions = AccountSessionVault(InMemorySecretVault())
        val pool = Executors.newFixedThreadPool(8)
        val accountLocks = ConcurrentHashMap<String, Any>()
        try {
            val jobs = (0 until 64).map { index ->
                pool.submit {
                    val account = "account-${index % 2}"
                    synchronized(accountLocks.computeIfAbsent(account) { Any() }) {
                        val generation = sessions.read(account)?.generation
                        sessions.write(account, generation, byteArrayOf(index.toByte()))
                    }
                }
            }
            jobs.forEach { it.get() }
            val left = requireNotNull(sessions.read("account-0"))
            val right = requireNotNull(sessions.read("account-1"))
            assertEquals(31L, left.generation)
            assertEquals(31L, right.generation)
            assertEquals(1, left.payload.size)
            assertEquals(1, right.payload.size)
        } finally {
            pool.shutdownNow()
        }
    }

    @Test fun staleRefreshCannotOverwriteNewerCredentials() {
        val sessions = AccountSessionVault(InMemorySecretVault())
        val generation0 = sessions.write("account-a", null, byteArrayOf(1))
        val refreshA = requireNotNull(sessions.read("account-a"))
        val refreshB = requireNotNull(sessions.read("account-a"))
        assertEquals(generation0 + 1, sessions.write("account-a", refreshA.generation, byteArrayOf(2)))
        try {
            sessions.write("account-a", refreshB.generation, byteArrayOf(3))
            fail("Stale refresh unexpectedly replaced newer credentials")
        } catch (_: StaleSessionWriteException) {
            assertArrayEquals(byteArrayOf(2), requireNotNull(sessions.read("account-a")).payload)
        }
    }

    @Test fun vaultCopiesInputAndOutputBuffers() {
        val vault = InMemorySecretVault()
        val source = byteArrayOf(4, 5)
        vault.write("account-a", source)
        source[0] = 99
        val read = requireNotNull(vault.read("account-a"))
        assertArrayEquals(byteArrayOf(4, 5), read)
        read[1] = 99
        assertArrayEquals(byteArrayOf(4, 5), vault.read("account-a"))
    }

    private fun assertFailure(message: String, action: () -> Unit) {
        try {
            action()
            fail("Expected session validation failure")
        } catch (error: IllegalStateException) {
            val messages = generateSequence<Throwable>(error) { it.cause }.mapNotNull(Throwable::getMessage).joinToString(" ")
            check(messages.contains(message))
        }
    }

    private fun envelope(owner: String, generation: Long, payload: ByteArray) =
        java.io.ByteArrayOutputStream().also { buffer ->
            java.io.DataOutputStream(buffer).use { output ->
                output.writeInt(0x53455054)
                output.writeUTF(owner)
                output.writeLong(generation)
                output.writeInt(payload.size)
                output.write(payload)
            }
        }.toByteArray()
}
