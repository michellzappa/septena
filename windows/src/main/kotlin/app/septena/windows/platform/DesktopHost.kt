package app.septena.windows.platform

import app.septena.core.generated.RegistryPlatformIds
import java.awt.Desktop
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

interface DesktopPaths {
    fun accountDirectory(accountId: String): Path
    fun cacheDirectory(): Path
}

interface SecretVault {
    fun read(accountId: String): ByteArray?
    fun write(accountId: String, payload: ByteArray)
    fun delete(accountId: String)
}

typealias ClientIdentity = app.septena.transport.ClientIdentity

/** A small account-bound envelope keeps corruption, ownership and refresh ordering above the OS vault. */
internal class AccountSessionVault(private val vault: SecretVault) {
    data class Session(val generation: Long, val payload: ByteArray)

    fun read(accountId: String): Session? = synchronized(lockFor(accountId)) {
        val bytes = vault.read(accountId) ?: return@synchronized null
        try {
            java.io.DataInputStream(bytes.inputStream()).use { input ->
                require(input.readInt() == MAGIC) { "Invalid session envelope" }
                val owner = input.readUTF()
                require(owner == accountId) { "Session belongs to another account" }
                val generation = input.readLong()
                val length = input.readInt()
                require(generation >= 0 && length in 0..MAX_PAYLOAD && length == input.available()) { "Invalid session envelope" }
                Session(generation, ByteArray(length).also(input::readFully))
            }
        } catch (error: Exception) {
            throw IllegalStateException("Could not read the saved session", error)
        }
    }

    fun write(accountId: String, expectedGeneration: Long?, payload: ByteArray): Long = synchronized(lockFor(accountId)) {
        require(accountId.isNotBlank())
        require(payload.size <= MAX_PAYLOAD)
        val current = read(accountId)
        if (current?.generation != expectedGeneration) throw StaleSessionWriteException()
        val next = (current?.generation ?: -1L) + 1
        val bytes = java.io.ByteArrayOutputStream().also { buffer ->
            java.io.DataOutputStream(buffer).use { output ->
                output.writeInt(MAGIC)
                output.writeUTF(accountId)
                output.writeLong(next)
                output.writeInt(payload.size)
                output.write(payload)
            }
        }.toByteArray()
        vault.write(accountId, bytes)
        next
    }

    fun delete(accountId: String) = synchronized(lockFor(accountId)) { vault.delete(accountId) }

    private fun lockFor(accountId: String): Any = locks.computeIfAbsent(accountId) { Any() }

    companion object {
        private const val MAGIC = 0x53455054 // "SEPT"
        private const val MAX_PAYLOAD = 1 shl 20
        private val locks = ConcurrentHashMap<String, Any>()
    }
}

internal class StaleSessionWriteException : IllegalStateException("Session changed while credentials were refreshing")

data class DesktopHost(
    val paths: DesktopPaths,
    val vault: SecretVault,
    val identity: ClientIdentity,
    val system: SystemBridge,
) {
    companion object {
        fun current(): DesktopHost = if (System.getProperty("os.name").startsWith("Windows", ignoreCase = true)) {
            app.septena.windows.platform.windows.WindowsDesktopHost.create()
        } else {
            FallbackDesktopHost.create()
        }
    }
}

interface SystemBridge {
    fun openExternalUrl(url: String)
}

private object FallbackDesktopHost {
    fun create(): DesktopHost {
        val root = Files.createTempDirectory("septena-desktop-host-")
        val vault = InMemorySecretVault()
        return DesktopHost(
            paths = object : DesktopPaths {
                override fun accountDirectory(accountId: String): Path = root.resolve("accounts").resolve(safeAccountName(accountId))
                override fun cacheDirectory(): Path = root.resolve("cache")
            },
            vault = vault,
            identity = ClientIdentity(RegistryPlatformIds.LINUX, "septena-linux", "Septena Linux"),
            system = AwtSystemBridge,
        )
    }
}

internal fun safeAccountName(accountId: String): String {
    require(accountId.isNotBlank()) { "Account ID must not be blank" }
    return Base64.getUrlEncoder().withoutPadding().encodeToString(accountId.toByteArray(Charsets.UTF_8))
}

internal class InMemorySecretVault : SecretVault {
    private val entries = ConcurrentHashMap<String, ByteArray>()

    override fun read(accountId: String): ByteArray? = entries[accountId]?.clone()
    override fun write(accountId: String, payload: ByteArray) { entries[accountId] = payload.clone() }
    override fun delete(accountId: String) { entries.remove(accountId) }
}

internal object AwtSystemBridge : SystemBridge {
    override fun openExternalUrl(url: String) {
        require(URI(url).scheme in setOf("https", "http")) { "Only HTTP(S) URLs can be opened" }
        if (Desktop.isDesktopSupported()) Desktop.getDesktop().browse(URI(url))
    }
}
