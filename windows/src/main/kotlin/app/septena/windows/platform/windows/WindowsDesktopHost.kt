package app.septena.windows.platform.windows

import app.septena.core.generated.RegistryPlatformIds
import app.septena.windows.platform.DesktopHost
import app.septena.windows.platform.ClientIdentity
import app.septena.windows.platform.DesktopPaths
import app.septena.windows.platform.SecretVault
import app.septena.windows.platform.AwtSystemBridge
import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.Structure
import com.sun.jna.WString
import com.sun.jna.ptr.PointerByReference
import com.sun.jna.win32.W32APIOptions
import com.sun.jna.win32.StdCallLibrary
import java.nio.file.Files
import java.nio.file.Path

internal object WindowsDesktopHost {
    fun create(): DesktopHost {
        val localAppData = System.getenv("LOCALAPPDATA")?.takeIf(String::isNotBlank)
            ?: error("LOCALAPPDATA is not set")
        val root = Path.of(localAppData).resolve("Septena")
        return DesktopHost(
            paths = object : DesktopPaths {
                override fun accountDirectory(accountId: String): Path = root.resolve("accounts").resolve(accountFolder(accountId))
                override fun cacheDirectory(): Path = root.resolve("cache")
            },
            vault = DpapiSecretVault(),
            identity = ClientIdentity(RegistryPlatformIds.WINDOWS, "septena-windows", "Septena Windows"),
            system = AwtSystemBridge,
        )
    }

    private fun accountFolder(accountId: String): String {
        require(accountId.isNotBlank()) { "Account ID must not be blank" }
        val bytes = java.security.MessageDigest.getInstance("SHA-256").digest(accountId.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

/** Current-user DPAPI protects each opaque account-session payload at rest. */
internal class DpapiSecretVault : SecretVault {
    private val directory: Path = Path.of(System.getenv("LOCALAPPDATA") ?: error("LOCALAPPDATA is not set"))
        .resolve("Septena").resolve("secrets")

    override fun read(accountId: String): ByteArray? {
        val file = fileFor(accountId)
        if (!Files.exists(file)) return null
        val encrypted = Files.readAllBytes(file)
        return dpapi(encrypted) { input, output -> Crypt32.INSTANCE.CryptUnprotectData(input, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, output) }
    }

    override fun write(accountId: String, payload: ByteArray) {
        val file = fileFor(accountId)
        Files.createDirectories(file.parent)
        val protected = dpapi(payload) { input, output -> Crypt32.INSTANCE.CryptProtectData(input, WString("Septena session"), null, null, null, CRYPTPROTECT_UI_FORBIDDEN, output) }
        val partial = Files.createTempFile(file.parent, "session-", ".tmp")
        try {
            Files.write(partial, protected)
            try {
                Files.move(partial, file, java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(partial, file, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            Files.deleteIfExists(partial)
        }
    }

    override fun delete(accountId: String) { Files.deleteIfExists(fileFor(accountId)) }

    private fun fileFor(accountId: String): Path {
        require(accountId.isNotBlank()) { "Account ID must not be blank" }
        val name = java.security.MessageDigest.getInstance("SHA-256").digest(accountId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) } + ".dpapi"
        return directory.resolve(name)
    }
}

private const val CRYPTPROTECT_UI_FORBIDDEN = 0x1

internal interface Crypt32 : StdCallLibrary {
    fun CryptProtectData(input: DataBlob, description: WString?, entropy: DataBlob?, reserved: Pointer?, prompt: Pointer?, flags: Int, output: DataBlob): Boolean
    fun CryptUnprotectData(input: DataBlob, description: PointerByReference?, entropy: DataBlob?, reserved: Pointer?, prompt: Pointer?, flags: Int, output: DataBlob): Boolean

    companion object {
        val INSTANCE: Crypt32 = Native.load("Crypt32", Crypt32::class.java, W32APIOptions.DEFAULT_OPTIONS)
    }
}

internal interface Kernel32 : StdCallLibrary {
    fun LocalFree(memory: Pointer): Pointer

    companion object {
        val INSTANCE: Kernel32 = Native.load("Kernel32", Kernel32::class.java, W32APIOptions.DEFAULT_OPTIONS)
    }
}

@Structure.FieldOrder("cbData", "pbData")
internal class DataBlob : Structure {
    @JvmField var cbData: Int = 0
    @JvmField var pbData: Pointer? = null

    constructor() : super()
    constructor(memory: Memory, size: Int) : super() { cbData = size; pbData = memory; write() }
}

private fun dpapi(payload: ByteArray = ByteArray(0), call: (DataBlob, DataBlob) -> Boolean): ByteArray {
    val inputMemory = Memory(payload.size.coerceAtLeast(1).toLong())
    if (payload.isNotEmpty()) inputMemory.write(0, payload, 0, payload.size)
    val input = DataBlob(inputMemory, payload.size)
    val output = DataBlob()
    try {
        check(call(input, output)) { "Windows DPAPI call failed (error ${Native.getLastError()})" }
        output.read()
        val pointer = requireNotNull(output.pbData)
        return try { pointer.getByteArray(0, output.cbData) } finally { Kernel32.INSTANCE.LocalFree(pointer) }
    } finally {
        inputMemory.clear()
    }
}
