package app.septena.android

import android.content.Context
import app.septena.core.Avatar
import app.septena.core.JsonValue
import app.septena.core.longValue
import app.septena.core.stringValue
import app.septena.transport.AccessHttpException
import app.septena.transport.SeptenaAvatarClient
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** What the editor says about a photo that is not on the server yet (surfaces.json `avatar.copy`). */
enum class AvatarPhotoNotice { Pending, TooLarge, Failed }

/**
 * The account's avatar on this device (#857). Keeps the last `GET /v1/account` avatar and its photo
 * on disk, so the avatar shows at launch without network. An edit shows at once and waits on disk
 * until the server has it: initials and emoji as a pending PATCH with the time of the edit, a photo
 * as the cropped JPEG. [flush] sends what waits; the app calls it after each sync (foreground,
 * connectivity, live nudges) and after sign-in. Sign-out clears it all. Member photos are cached by
 * their photo id.
 */
class AvatarStore(
    context: Context,
    private val client: SeptenaAvatarClient,
    private val scope: CoroutineScope,
) {
    private val root = File(context.filesDir, "avatar")
    private val memberRoot = File(context.cacheDir, "avatar-members")
    private val accountFile = File(root, "account.json")
    private val pendingEditFile = File(root, "pending.json")
    private val pendingPhotoFile = File(root, "pending.jpg")
    private val mutex = Mutex()
    private val memberMutex = Mutex()

    /** The account this cache belongs to. */
    @Volatile private var owner: String? = null
    @Volatile private var stored: Avatar? = null

    private val _avatar = MutableStateFlow<Avatar?>(null)
    /** The avatar to draw: the stored one with any edit that waits on top. Null before anything is known. */
    val avatar: StateFlow<Avatar?> = _avatar.asStateFlow()

    private val _photo = MutableStateFlow<File?>(null)
    /** The file of the photo [avatar] shows, when it is on this device. */
    val photo: StateFlow<File?> = _photo.asStateFlow()

    private val _notice = MutableStateFlow<AvatarPhotoNotice?>(null)
    val notice: StateFlow<AvatarPhotoNotice?> = _notice.asStateFlow()

    private var loaded = false

    init {
        scope.launch(Dispatchers.IO) { locked { } }
    }

    /** Every read and write runs here, after the cache is read from disk once. */
    private suspend inline fun <T> locked(block: () -> T): T = mutex.withLock {
        if (!loaded) {
            loaded = true
            load()
        }
        block()
    }

    /** After sign-in or an account switch: drops another account's cache, then reads the server. */
    fun signedIn(userId: String) {
        scope.launch(Dispatchers.IO) {
            locked {
                if (owner != null && owner != userId) wipe()
                owner = userId
            }
            flush()
            refresh()
        }
    }

    /** Sign-out: nothing of this account stays. */
    fun signedOut() {
        scope.launch(Dispatchers.IO) { locked { wipe() } }
    }

    /** Sends what waits, in the background. */
    fun requestFlush() {
        if (!pendingEditFile.exists() && !pendingPhotoFile.exists()) return
        scope.launch(Dispatchers.IO) { flush() }
    }

    /** Reads the server's avatar. An edit that waits wins until it is sent. Offline keeps the cache. */
    suspend fun refresh() = withContext(Dispatchers.IO) {
        val fresh = try {
            client.account()
        } catch (failure: IOException) {
            return@withContext
        }
        locked {
            if (pendingEditFile.exists() || pendingPhotoFile.exists()) return@locked
            adopt(fresh)
        }
    }

    /** Initials or an emoji. Shows at once; the server gets it now or when this device is online. */
    suspend fun save(kind: String, emoji: String?, color: String, initials: String) = withContext(Dispatchers.IO) {
        locked {
            root.mkdirs()
            pendingPhotoFile.delete()
            _notice.value = null
            val edit = JsonValue.ObjectValue(
                buildMap {
                    put("op", JsonValue.StringValue(OP_SET))
                    put("kind", JsonValue.StringValue(kind))
                    emoji?.let { put("emoji", JsonValue.StringValue(it)) }
                    put("color", JsonValue.StringValue(color))
                    put("initials", JsonValue.StringValue(initials))
                    put("updatedAt", JsonValue.IntegerValue(System.currentTimeMillis()))
                },
            )
            pendingEditFile.writeText(edit.canonicalJson())
            publish()
        }
        flush()
    }

    /** A cropped JPEG. It uploads only online; until then the editor says so. */
    suspend fun savePhoto(jpeg: ByteArray) = withContext(Dispatchers.IO) {
        locked {
            root.mkdirs()
            pendingEditFile.delete()
            val partial = File(root, "pending.jpg.part")
            partial.writeBytes(jpeg)
            if (!partial.renameTo(pendingPhotoFile)) {
                partial.delete()
                _notice.value = AvatarPhotoNotice.Failed
                return@locked
            }
            _notice.value = AvatarPhotoNotice.Pending
            publish()
        }
        flush()
    }

    /** Back to initials (`DELETE /v1/account/avatar`). Waits like any edit when offline. */
    suspend fun removePhoto() = withContext(Dispatchers.IO) {
        locked {
            root.mkdirs()
            pendingPhotoFile.delete()
            _notice.value = null
            val edit = JsonValue.ObjectValue(
                mapOf(
                    "op" to JsonValue.StringValue(OP_REMOVE),
                    "updatedAt" to JsonValue.IntegerValue(System.currentTimeMillis()),
                ),
            )
            pendingEditFile.writeText(edit.canonicalJson())
            publish()
        }
        flush()
    }

    /** Sends the edit or the photo that waits. A network failure keeps it for the next try. */
    suspend fun flush() = withContext(Dispatchers.IO) {
        locked {
            if (pendingPhotoFile.exists()) {
                try {
                    val written = client.uploadPhoto(pendingPhotoFile)
                    val id = written.avatar.photoId
                    if (written.avatar.showsPhoto && id != null) pendingPhotoFile.renameTo(photoFile(id))
                    pendingPhotoFile.delete()
                    _notice.value = null
                    adopt(written.avatar)
                } catch (failure: AccessHttpException) {
                    pendingPhotoFile.delete()
                    _notice.value = if (failure.statusCode == 413) AvatarPhotoNotice.TooLarge else AvatarPhotoNotice.Failed
                    publish()
                } catch (failure: IOException) {
                    _notice.value = AvatarPhotoNotice.Pending
                }
                return@locked
            }
            val edit = readEdit() ?: return@locked
            try {
                val avatar = if (edit.fields["op"].stringValue() == OP_REMOVE) {
                    client.removePhoto()
                } else {
                    // A late edit older than the stored one comes back with applied false: adopt what came back.
                    client.update(
                        kind = edit.fields["kind"].stringValue() ?: Avatar.KIND_INITIALS,
                        emoji = edit.fields["emoji"].stringValue(),
                        color = edit.fields["color"].stringValue()?.takeIf(String::isNotEmpty),
                        initials = edit.fields["initials"].stringValue(),
                        updatedAtMs = edit.fields["updatedAt"].longValue() ?: 0L,
                    ).avatar
                }
                pendingEditFile.delete()
                adopt(avatar)
            } catch (failure: AccessHttpException) {
                // The server refused the edit itself; trying again sends the same refusal.
                pendingEditFile.delete()
                publish()
            } catch (failure: IOException) {
                // Offline or signed out: the edit waits.
            }
        }
    }

    /** A member's photo on this device, fetched once per photo id. Null while offline or refused. */
    suspend fun memberPhoto(shareId: String, memberId: String, photoId: String): File? = withContext(Dispatchers.IO) {
        val file = File(memberRoot, "${safeName(photoId)}.jpg")
        if (file.exists()) return@withContext file
        memberMutex.withLock {
            if (!file.exists()) {
                memberRoot.mkdirs()
                try {
                    client.downloadMemberPhoto(shareId, memberId, photoId, file)
                } catch (failure: IOException) {
                    // Drawn as initials on the color; the next draw tries again.
                }
            }
        }
        file.takeIf(File::exists)
    }

    private fun load() {
        val saved = runCatching { JsonValue.parse(accountFile.readText()) as? JsonValue.ObjectValue }.getOrNull()
        owner = saved?.fields?.get("userId").stringValue()
        stored = Avatar.from(saved?.fields?.get("avatar"))
        publish()
    }

    /** Keeps [avatar] as the server's and fetches its photo when this device has none. */
    private suspend fun adopt(avatar: Avatar) {
        stored = avatar
        root.mkdirs()
        val saved = buildMap<String, JsonValue> {
            owner?.let { put("userId", JsonValue.StringValue(it)) }
            put("avatar", avatar.toJson())
        }
        accountFile.writeText(JsonValue.ObjectValue(saved).canonicalJson())
        val id = avatar.photoId
        if (avatar.showsPhoto && id != null && !photoFile(id).exists()) {
            try {
                client.downloadOwnPhoto(id, photoFile(id))
            } catch (failure: IOException) {
                // Drawn as initials on the color until the next refresh fetches it.
            }
        }
        // One photo on disk: the one the avatar shows.
        root.listFiles()?.filter { it.name.startsWith(PHOTO_PREFIX) && it.name != id?.let(::photoName) }
            ?.forEach(File::delete)
        publish()
    }

    /** Draws the stored avatar with the edit that waits on top. */
    private fun publish() {
        val base = stored
        val edit = readEdit()
        val shown: Avatar? = when {
            pendingPhotoFile.exists() ->
                (base ?: Avatar(Avatar.KIND_PHOTO, "")).copy(kind = Avatar.KIND_PHOTO, emoji = null, photoId = PENDING_PHOTO_ID)
            edit != null && edit.fields["op"].stringValue() == OP_REMOVE ->
                (base ?: Avatar(Avatar.KIND_INITIALS, "")).copy(kind = Avatar.KIND_INITIALS, emoji = null, photoId = null)
            edit != null -> {
                val kind = edit.fields["kind"].stringValue() ?: Avatar.KIND_INITIALS
                Avatar(
                    kind = kind,
                    color = edit.fields["color"].stringValue()?.takeIf(String::isNotEmpty) ?: base?.color.orEmpty(),
                    initials = edit.fields["initials"].stringValue()?.takeIf(String::isNotBlank),
                    emoji = edit.fields["emoji"].stringValue()?.takeIf { kind == Avatar.KIND_EMOJI },
                    updatedAt = edit.fields["updatedAt"].longValue() ?: 0L,
                )
            }
            else -> base
        }
        _avatar.value = shown
        _photo.value = when {
            shown?.photoId == PENDING_PHOTO_ID -> pendingPhotoFile
            shown?.showsPhoto == true -> shown?.photoId?.let(::photoFile)?.takeIf(File::exists)
            else -> null
        }
    }

    private fun readEdit(): JsonValue.ObjectValue? =
        runCatching { JsonValue.parse(pendingEditFile.readText()) as? JsonValue.ObjectValue }.getOrNull()

    private fun wipe() {
        root.deleteRecursively()
        memberRoot.deleteRecursively()
        owner = null
        stored = null
        _notice.value = null
        publish()
    }

    private fun photoFile(photoId: String) = File(root, photoName(photoId))

    private fun photoName(photoId: String) = "$PHOTO_PREFIX${safeName(photoId)}.jpg"

    private fun safeName(id: String) = id.filter { it.isLetterOrDigit() || it == '-' || it == '_' }.take(64)

    private companion object {
        const val OP_SET = "set"
        const val OP_REMOVE = "remove"
        const val PHOTO_PREFIX = "photo-"
        /** The photo id of a cropped photo that is not on the server yet. */
        const val PENDING_PHOTO_ID = "pending"
    }
}
