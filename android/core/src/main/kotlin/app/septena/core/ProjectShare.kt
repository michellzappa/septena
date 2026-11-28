package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames

/** One person in a shared project. [avatar] is null when the server sent none: initials on the neutral fill. */
data class ShareMember(val id: String, val name: String, val isOwner: Boolean, val avatar: Avatar? = null)

/**
 * Who shares a project: the project row's server-owned `share` column
 * (docs/PROJECT_SHARING_SPEC.md, backend `ShareInfo`). Pulled, never pushed.
 */
data class ProjectShare(
    val id: String,
    val isOwner: Boolean,
    /** This account's member id. */
    val me: String,
    val members: List<ShareMember>,
) {
    fun member(id: String): ShareMember? = members.firstOrNull { it.id == id }

    companion object {
        const val ROLE_OWNER = "owner"

        /** Null for a private project, and for a value this build cannot read. */
        fun from(value: JsonValue?): ProjectShare? {
            val fields = (value as? JsonValue.ObjectValue)?.fields ?: return null
            return ProjectShare(
                id = fields["id"].stringValue() ?: return null,
                isOwner = fields["role"].stringValue() == ROLE_OWNER,
                me = fields["me"].stringValue() ?: return null,
                members = (fields["members"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { raw ->
                    val member = (raw as? JsonValue.ObjectValue)?.fields ?: return@mapNotNull null
                    ShareMember(
                        id = member["id"].stringValue() ?: return@mapNotNull null,
                        name = member["name"].stringValue().orEmpty(),
                        isOwner = member["role"].stringValue() == ROLE_OWNER,
                        avatar = Avatar.from(member["avatar"]),
                    )
                },
            )
        }

        fun of(project: SyncRecord?): ProjectShare? =
            project?.takeIf { it.deletedAt == null }?.let { from(it.fields[RegistryEntityFields.Project.SHARE]) }

        /** The shared projects of this account, by project id. */
        suspend fun byProject(store: TaskStore): Map<String, ProjectShare> = buildMap {
            for (project in store.records(RegistryEntityNames.PROJECT)) of(project)?.let { put(project.id, it) }
        }
    }
}

/**
 * An invite link: `https://api.septena.app/join/<token>` or `septask://join/<token>`.
 * Anything else is null.
 */
object ShareInviteLink {
    private val TOKEN = Regex("^sp_[A-Za-z0-9_-]{32}\\.[A-Za-z0-9_-]{32}$")

    fun token(input: String, host: String): String? {
        val uri = runCatching { java.net.URI(input.trim()) }.getOrNull() ?: return null
        val path = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
        val token = when {
            uri.scheme == "https" && uri.host.equals(host, ignoreCase = true) && path.size == 2 && path[0] == "join" -> path[1]
            uri.scheme == "septask" && uri.authority == "join" && path.size == 1 -> path[0]
            else -> null
        }
        return token?.takeIf(TOKEN::matches)
    }
}

/**
 * Rejections that the next pull settles by itself: a change a shared project does not
 * allow. The server sends the real row again, so there is nothing to retry.
 */
object ShareRejections {
    val reasons: Set<String> = setOf("shared_project", "shared_move_out")
}
