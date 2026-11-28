package app.septena.transport

import app.septena.core.Avatar
import app.septena.core.JsonValue
import app.septena.core.booleanValue
import java.io.File
import java.net.HttpURLConnection

/** What a write answers: the stored avatar, and false when a newer edit was already there. */
data class AvatarWrite(val avatar: Avatar, val applied: Boolean)

/**
 * The account's avatar (#857, backend `src/api/avatar.ts`): `GET /v1/account`,
 * `PATCH|PUT|DELETE /v1/account/avatar`, and the photo reads. Same bearer and
 * refresh-on-401 rule as [SeptenaAccessClient]. Throws [AccessHttpException].
 */
class SeptenaAvatarClient(
    private val credentials: SyncCredentials,
    private val clientVersion: String,
    private val baseUrl: String = JsonHttp.DEFAULT_BASE_URL,
) {
    /** The account's avatar. */
    suspend fun account(): Avatar {
        val json = json(authed { JsonHttp.send(baseUrl, "/v1/account", "GET", null, clientVersion, bearer = it) })
        return Avatar.from(json.fields["avatar"]) ?: error("An account without an avatar")
    }

    /**
     * Initials or an emoji. A null [color] or [initials] keeps the stored one; "" initials derives
     * them from the name again. [updatedAtMs] is when the person made the edit.
     */
    suspend fun update(kind: String, emoji: String?, color: String?, initials: String?, updatedAtMs: Long): AvatarWrite {
        val fields = buildMap<String, JsonValue> {
            put("kind", JsonValue.StringValue(kind))
            if (kind == Avatar.KIND_EMOJI) put("emoji", JsonValue.StringValue(emoji.orEmpty()))
            color?.let { put("color", JsonValue.StringValue(it)) }
            initials?.let { put("initials", JsonValue.StringValue(it)) }
            if (updatedAtMs > 0) put("updatedAt", JsonValue.IntegerValue(updatedAtMs))
        }
        val body = JsonValue.ObjectValue(fields).canonicalJson()
        return write(authed { JsonHttp.send(baseUrl, PATH, "PATCH", body, clientVersion, bearer = it) })
    }

    /** A new photo: [jpeg] is the cropped square. 413 when too big, 415 when not an image. */
    suspend fun uploadPhoto(jpeg: File): AvatarWrite =
        write(
            authed {
                JsonHttp.transfer(baseUrl, PATH, "PUT", clientVersion, it, upload = jpeg, uploadType = "image/jpeg")
            },
        )

    /** Back to initials; the server deletes the photo. */
    suspend fun removePhoto(): Avatar {
        val json = json(authed { JsonHttp.send(baseUrl, PATH, "DELETE", null, clientVersion, bearer = it) })
        return Avatar.from(json.fields["avatar"]) ?: error("A reply without an avatar")
    }

    /** The account's own photo into [destination]. */
    suspend fun downloadOwnPhoto(photoId: String, destination: File) {
        authed {
            JsonHttp.transfer(baseUrl, "$PATH/photo?v=${photoId.encoded()}", "GET", clientVersion, it, download = destination)
        }
    }

    /** A member's photo into [destination]. 404 unless this account is in the share. */
    suspend fun downloadMemberPhoto(shareId: String, memberId: String, photoId: String, destination: File) {
        val path = "/v1/shares/${shareId.encoded()}/members/${memberId.encoded()}/avatar?v=${photoId.encoded()}"
        authed { JsonHttp.transfer(baseUrl, path, "GET", clientVersion, it, download = destination) }
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
        if (final.statusCode !in 200..299) throw AccessHttpException(final.statusCode, final.body)
        return final.body
    }

    private fun write(body: String): AvatarWrite {
        val json = json(body)
        return AvatarWrite(
            avatar = Avatar.from(json.fields["avatar"]) ?: error("A reply without an avatar"),
            applied = json.fields["applied"].booleanValue() ?: true,
        )
    }

    private fun json(body: String): JsonValue.ObjectValue =
        JsonValue.parse(body) as? JsonValue.ObjectValue ?: error("Expected a JSON object")

    private fun String.encoded(): String =
        java.net.URLEncoder.encode(this, Charsets.UTF_8.name()).replace("+", "%20")

    private companion object {
        const val PATH = "/v1/account/avatar"
    }
}
