package app.septena.transport

import app.septena.core.JsonValue
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.longValue
import app.septena.core.stringValue
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection

/** One row of the change log (`GET /v1/changes`). [diff] maps a field to its `[before, after]` values. */
data class TaskChange(
    val rev: Long,
    val entity: String,
    val id: String,
    /** `upsert`, `delete`, `dropped`, `append`, `upload` or a claim op. */
    val op: String,
    val fields: List<String>?,
    val diff: Map<String, Pair<JsonValue, JsonValue>>,
    val actor: String,
    val at: String,
    val reason: String?,
)

data class TaskChangesPage(
    /** Newest first. */
    val changes: List<TaskChange>,
    /** Changes older than the plan's window that the server did not send. */
    val hiddenOlder: Long?,
    /** The upsell moment for the end of the list (`history_edge`), set only on the free plan. */
    val upsell: String?,
)

class TaskBackendHttpException(val statusCode: Int, val responseBody: String) : IOException(
    "Septena task backend returned HTTP $statusCode",
)

/**
 * The task backend's routes that sync does not cover (docs/SEPTASK_BACKEND.md §10):
 * a task's change log, attachment bytes and account deletion.
 * Same bearer and refresh-on-401 rule as [UrlConnectionSyncTransport].
 */
class SeptenaTaskBackendClient(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    /** One task's change log, newest first. */
    suspend fun history(taskId: String, limit: Int = HISTORY_PAGE_SIZE): TaskChangesPage {
        val path = "/v1/changes?entity=${RegistryEntityNames.TASK}&id=${taskId.encoded()}&limit=${limit.coerceIn(1, 500)}"
        val body = authed { token -> JsonHttp.send(baseUrl, path, "GET", null, clientVersion, bearer = token) }
        val json = JsonValue.parse(body) as? JsonValue.ObjectValue ?: throw IOException("Expected a JSON object")
        val changes = (json.fields["changes"] as? JsonValue.ArrayValue)?.values.orEmpty().map { raw ->
            val row = raw as? JsonValue.ObjectValue ?: throw IOException("Change row is not an object")
            TaskChange(
                rev = row.fields["rev"].longValue() ?: throw IOException("Change row has no rev"),
                entity = row.fields["entity"].stringValue() ?: throw IOException("Change row has no entity"),
                id = row.fields["id"].stringValue() ?: throw IOException("Change row has no id"),
                op = row.fields["op"].stringValue() ?: throw IOException("Change row has no op"),
                fields = (row.fields["fields"] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() },
                diff = (row.fields["diff"] as? JsonValue.ObjectValue)?.fields.orEmpty().mapValues { (_, pair) ->
                    val values = (pair as? JsonValue.ArrayValue)?.values.orEmpty()
                    (values.getOrNull(0) ?: JsonValue.Null) to (values.getOrNull(1) ?: JsonValue.Null)
                },
                actor = row.fields["actor"].stringValue().orEmpty(),
                at = row.fields["at"].stringValue().orEmpty(),
                reason = row.fields["reason"].stringValue(),
            )
        }
        return TaskChangesPage(
            changes = changes,
            hiddenOlder = json.fields["hiddenOlder"].longValue(),
            upsell = json.fields["upsell"].stringValue(),
        )
    }

    /**
     * Uploads an attachment's bytes. The metadata row must be on the server
     * first and its `byteCount` must equal the file size, or the server
     * answers 404 / 409.
     */
    suspend fun uploadAttachment(id: String, file: File, contentType: String) {
        authed { token ->
            JsonHttp.transfer(
                baseUrl, "/v1/attachments/${id.encoded()}", "PUT", clientVersion, token,
                upload = file, uploadType = contentType,
            )
        }
    }

    /** Downloads an attachment's bytes into [destination], replacing it only when complete. */
    suspend fun downloadAttachment(id: String, destination: File) {
        authed { token ->
            JsonHttp.transfer(
                baseUrl, "/v1/attachments/${id.encoded()}", "GET", clientVersion, token,
                download = destination,
            )
        }
    }

    /**
     * Deletes the account (`DELETE /v1/account`, docs/SEPTASK_BACKEND.md §10): the server empties the
     * user's task store and attachment files. Throws when the server did not confirm.
     */
    suspend fun deleteAccount() {
        authed { token -> JsonHttp.send(baseUrl, "/v1/account", "DELETE", null, clientVersion, bearer = token) }
    }

    private suspend fun authed(request: suspend (String) -> HttpResponse): String {
        val firstToken = credentials.accessToken() ?: throw SyncAuthenticationException()
        val first = request(firstToken)
        val final = if (first.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            val renewed = credentials.refreshAfterUnauthorized() ?: throw SyncAuthenticationException()
            request(renewed)
        } else {
            first
        }
        if (final.statusCode !in 200..299) throw TaskBackendHttpException(final.statusCode, final.body)
        return final.body
    }

    private fun String.encoded(): String =
        java.net.URLEncoder.encode(this, Charsets.UTF_8.name()).replace("+", "%20")

    companion object {
        /** How many log rows one load asks for, as on iOS (`TaskHistory.pageSize`). */
        const val HISTORY_PAGE_SIZE = 50
    }
}
