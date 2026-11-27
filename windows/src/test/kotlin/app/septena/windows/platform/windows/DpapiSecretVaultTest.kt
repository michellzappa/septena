package app.septena.windows.platform.windows

import org.junit.Assert.assertArrayEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

class DpapiSecretVaultTest {
    @Test fun currentUserDpapiRoundTripAndDelete() {
        assumeTrue(System.getProperty("os.name").startsWith("Windows", ignoreCase = true))
        val account = "dpapi-contract-${System.nanoTime()}"
        val vault = DpapiSecretVault()
        val payload = "opaque-session-fixture".toByteArray()
        try {
            vault.write(account, payload)
            assertArrayEquals(payload, vault.read(account))
        } finally {
            vault.delete(account)
        }
        org.junit.Assert.assertNull(vault.read(account))
    }
}
