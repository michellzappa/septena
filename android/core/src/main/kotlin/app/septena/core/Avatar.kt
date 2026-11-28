package app.septena.core

/**
 * A person's avatar (#857, backend `src/store/avatar.ts`): initials, one emoji or a photo, on a fill
 * from tokens.json `avatarColors`. The account's comes from `GET /v1/account`; a member's arrives in
 * the project row's `share` column. Read leniently: an unknown kind draws initials, an unknown color
 * draws the default color (Persimmon).
 */
data class Avatar(
    /** `initials`, `emoji` or `photo`; anything else draws as initials. */
    val kind: String,
    /** A fruit accent id (tokens.json `avatarColors`); empty or unknown draws the default color. */
    val color: String,
    /** The 1 to 3 letters the person typed; null derives them from the name. */
    val initials: String? = null,
    val emoji: String? = null,
    /** Changes with every new photo: the cache key and the `?v=` of the photo URL. */
    val photoId: String? = null,
    /** ms since 1970; 0 is the default avatar nobody set. */
    val updatedAt: Long = 0,
) {
    val showsPhoto: Boolean get() = kind == KIND_PHOTO && !photoId.isNullOrEmpty()
    val showsEmoji: Boolean get() = kind == KIND_EMOJI && !emoji.isNullOrEmpty()

    /** What the circle shows as text: the emoji, the typed initials, or the name's initials. */
    fun text(name: String): String = when {
        showsEmoji -> emoji.orEmpty()
        !initials.isNullOrBlank() -> initials
        else -> PersonInitials.of(name)
    }

    fun toJson(): JsonValue.ObjectValue = JsonValue.ObjectValue(
        buildMap {
            put("kind", JsonValue.StringValue(kind))
            put("color", JsonValue.StringValue(color))
            initials?.let { put("initials", JsonValue.StringValue(it)) }
            emoji?.let { put("emoji", JsonValue.StringValue(it)) }
            photoId?.let { put("photoId", JsonValue.StringValue(it)) }
            put("updatedAt", JsonValue.IntegerValue(updatedAt))
        },
    )

    companion object {
        const val KIND_INITIALS = "initials"
        const val KIND_EMOJI = "emoji"
        const val KIND_PHOTO = "photo"

        /** Null only when [value] is not an object. Missing fields fall back to the default look. */
        fun from(value: JsonValue?): Avatar? {
            val fields = (value as? JsonValue.ObjectValue)?.fields ?: return null
            return Avatar(
                kind = fields["kind"].stringValue() ?: KIND_INITIALS,
                color = fields["color"].stringValue().orEmpty(),
                initials = fields["initials"].stringValue()?.takeIf(String::isNotBlank),
                emoji = fields["emoji"].stringValue()?.takeIf(String::isNotEmpty),
                photoId = fields["photoId"].stringValue()?.takeIf(String::isNotEmpty),
                updatedAt = fields["updatedAt"].longValue() ?: 0L,
            )
        }
    }
}

/** A name's initials, as every avatar draws them (Swift `PersonInitials`). */
object PersonInitials {
    /** One word: the word itself when it has up to 3 letters, else its first letter. More words: the first two first letters. */
    fun of(name: String): String {
        val words = name.trim().split(' ').filter(String::isNotEmpty)
        if (words.size <= 1) {
            val token = words.firstOrNull().orEmpty()
            return (if (token.length <= 3) token else token.take(1)).uppercase()
        }
        return words.take(2).joinToString("") { it.take(1) }.uppercase()
    }
}
