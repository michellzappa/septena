package app.septena.android

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.RegistryEntityMutator
import app.septena.core.SyncRecord
import app.septena.core.TaskStore
import app.septena.core.WireTimestamp
import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.longValue
import app.septena.core.stringValue
import app.septena.transport.SeptenaTaskBackendClient
import app.septena.transport.TaskBackendHttpException
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** A file that is larger than the server takes (`maxAttachmentBytes`). */
class AttachmentTooLargeException : IOException("Attachment is larger than the limit")

/**
 * Task attachments on Android (feature `task.attachments`, docs/ATTACHMENTS_MAC_PARITY_SPEC.md).
 * The metadata row syncs like any registry entity. The bytes live in the app's
 * files directory (`attachments/<id>/<filename>`) and go to the server after the
 * row is on the server (`PUT /v1/attachments/:id`), as on iOS. A file that is
 * not on this device is fetched on first open (`GET /v1/attachments/:id`).
 */
class TaskAttachmentStore(
    context: Context,
    private val store: TaskStore,
    private val mutator: RegistryEntityMutator,
    private val clock: DayClock,
    private val backend: SeptenaTaskBackendClient,
) {
    private val resolver = context.contentResolver
    private val root = File(context.filesDir, ROOT_DIRECTORY)
    private val incoming = File(context.cacheDir, INCOMING_DIRECTORY)

    /** Uploads that landed this run; the next pull brings their `uploadedAt`. */
    private val uploaded = ConcurrentHashMap.newKeySet<String>()

    /** Uploads the server refused for good this run (plan, size, deleted). Files stay on this device. */
    private val refused = ConcurrentHashMap.newKeySet<String>()

    suspend fun attachments(taskId: String): List<SyncRecord> =
        store.records(RegistryEntityNames.ATTACHMENT)
            .filter {
                it.deletedAt == null &&
                    it.fields[RegistryEntityFields.Attachment.TASK_ID].stringValue() == taskId
            }
            .sortedWith(
                compareBy<SyncRecord> { it.fields[RegistryEntityFields.Attachment.POSITION].numberValue() ?: 0.0 }
                    .thenBy { it.fields[RegistryEntityFields.Attachment.CREATED_AT].stringValue().orEmpty() },
            )

    /** Copies the picked document into the app and adds its row. The upload follows the next sync. */
    suspend fun add(taskId: String, uri: Uri): SyncRecord {
        val filename = displayName(uri).take(FILENAME_MAX)
        val contentType = (resolver.getType(uri) ?: GENERIC_TYPE).take(CONTENT_TYPE_MAX)
        incoming.mkdirs()
        val temporary = File(incoming, UUID.randomUUID().toString())
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("The file could not be read")
            input.use { source ->
                temporary.outputStream().use { target ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var total = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > RegistryEntityLimits.MAX_ATTACHMENT_BYTES) throw AttachmentTooLargeException()
                        target.write(buffer, 0, read)
                    }
                }
            }
            val position = attachments(taskId).size.toDouble()
            val record = mutator.create(
                RegistryEntityNames.ATTACHMENT,
                mapOf(
                    RegistryEntityFields.Attachment.TASK_ID to JsonValue.StringValue(taskId),
                    RegistryEntityFields.Attachment.FILENAME to JsonValue.StringValue(filename),
                    RegistryEntityFields.Attachment.CONTENT_TYPE to JsonValue.StringValue(contentType),
                    RegistryEntityFields.Attachment.BYTE_COUNT to JsonValue.IntegerValue(temporary.length()),
                    RegistryEntityFields.Attachment.POSITION to JsonValue.DecimalValue(position),
                    RegistryEntityFields.Attachment.CREATED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
                ),
            )
            val target = localFile(record)
            target.parentFile?.mkdirs()
            if (!temporary.renameTo(target)) {
                temporary.copyTo(target, overwrite = true)
            }
            return record
        } finally {
            temporary.delete()
        }
    }

    /** Deletes the row (the server then removes the bytes) and this device's copy. */
    suspend fun remove(record: SyncRecord) {
        mutator.delete(RegistryEntityNames.ATTACHMENT, record.id)
        deleteLocalCopy(record.id)
    }

    /** Removes this device's cached copy of an attachment deleted locally or on another device. */
    fun deleteLocalCopy(id: String) {
        File(root, id).deleteRecursively()
    }

    /** The file on this device, downloaded first when only the server has it. */
    suspend fun openableFile(record: SyncRecord): File {
        val file = localFile(record)
        if (file.isFile) return file
        backend.downloadAttachment(record.id, file)
        return file
    }

    /** A MIME type for an open intent. iOS rows may carry a UTI (`public.png`) instead. */
    fun mimeType(record: SyncRecord): String {
        val stored = record.fields[RegistryEntityFields.Attachment.CONTENT_TYPE].stringValue()
        if (stored != null && '/' in stored) return stored
        val extension = filename(record).substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: GENERIC_TYPE
    }

    fun filename(record: SyncRecord): String =
        record.fields[RegistryEntityFields.Attachment.FILENAME].stringValue()?.takeIf(String::isNotBlank) ?: record.id

    fun byteCount(record: SyncRecord): Long =
        record.fields[RegistryEntityFields.Attachment.BYTE_COUNT].longValue() ?: 0L

    /**
     * Runs after each sync. Uploads every row that is on the server without its
     * bytes when this device holds them. Remote attachment tombstones remove
     * their cached files as sync applies them ([deleteLocalCopy]); any locally
     * soft-deleted rows are cleaned up here too.
     * Returns true when an upload landed, so the caller pulls the new state.
     */
    suspend fun afterSync(): Boolean {
        val records = store.records(RegistryEntityNames.ATTACHMENT)
        val (deleted, live) = records.partition { it.deletedAt != null }
        // Only a known tombstone frees a copy: a row that is missing for a moment
        // (a reset pull) must never cost the only copy of a file.
        deleted.forEach { deleteLocalCopy(it.id) }
        var landed = false
        for (record in live) {
            if (record.revision == null) continue
            if (record.fields[RegistryEntityFields.Attachment.UPLOADED_AT].stringValue() != null) continue
            if (record.id in uploaded || record.id in refused) continue
            val file = localFile(record)
            if (!file.isFile || file.length() != byteCount(record)) continue
            try {
                backend.uploadAttachment(record.id, file, mimeType(record))
                uploaded += record.id
                landed = true
            } catch (error: TaskBackendHttpException) {
                // 404: the row is not on the server yet, so the next sync tries again.
                if (error.statusCode != HTTP_NOT_FOUND) refused += record.id
            }
        }
        return landed
    }

    private fun localFile(record: SyncRecord): File {
        // One directory per attachment id, so two files with one name never collide.
        val safe = filename(record).replace(UNSAFE_CHARACTERS, "_").trimStart('.').ifEmpty { record.id }
        return File(File(root, record.id), safe)
    }

    private fun displayName(uri: Uri): String {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index)?.takeIf(String::isNotBlank)?.let { return it }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf(String::isNotBlank) ?: UUID.randomUUID().toString()
    }

    private fun JsonValue?.numberValue(): Double? = when (this) {
        is JsonValue.IntegerValue -> value.toDouble()
        is JsonValue.DecimalValue -> value
        else -> null
    }

    private companion object {
        const val ROOT_DIRECTORY = "attachments"
        const val INCOMING_DIRECTORY = "attachments-incoming"
        const val GENERIC_TYPE = "application/octet-stream"
        const val BUFFER_BYTES = 64 * 1024
        const val HTTP_NOT_FOUND = 404
        val UNSAFE_CHARACTERS = Regex("[/\\\\:\\u0000]")
        val FILENAME_MAX = RegistryEntities.all.getValue(RegistryEntityNames.ATTACHMENT)
            .columns.getValue(RegistryEntityFields.Attachment.FILENAME).max?.toInt() ?: 512
        val CONTENT_TYPE_MAX = RegistryEntities.all.getValue(RegistryEntityNames.ATTACHMENT)
            .columns.getValue(RegistryEntityFields.Attachment.CONTENT_TYPE).max?.toInt() ?: 200
    }
}
