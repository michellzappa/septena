package app.septena.android.auth

import android.content.Context

/**
 * Persists the refresh token and user id, encrypted with an AES-GCM key held in the Android Keystore
 * (docs/ANDROID_CLIENT_SPEC.md §3). The access token stays in memory only.
 */
class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val sealer = KeystoreSealer(KEY_ALIAS)

    data class Saved(val refreshToken: String, val userId: String)

    @Synchronized
    fun load(): Saved? {
        val refresh = sealer.open(prefs.getString(KEY_REFRESH, null)) ?: return null
        val userId = prefs.getString(KEY_USER, null) ?: return null
        return Saved(refresh, userId)
    }

    /** False when the write failed: the previous session is still the stored one. */
    @Synchronized
    fun save(refreshToken: String, userId: String): Boolean {
        val oldRefresh = prefs.getString(KEY_REFRESH, null)
        val oldUser = prefs.getString(KEY_USER, null)
        // commit(), not apply(): the token must be on disk before its access token is used.
        if (prefs.edit().putString(KEY_REFRESH, sealer.seal(refreshToken)).putString(KEY_USER, userId).commit()) return true
        // A failed commit leaves the new values in memory. Memory must match the disk.
        prefs.edit().putString(KEY_REFRESH, oldRefresh).putString(KEY_USER, oldUser).commit()
        return false
    }

    @Synchronized
    fun clear() {
        prefs.edit().clear().commit()
    }

    private companion object {
        const val PREFS = "septena-session"
        const val KEY_REFRESH = "refresh"
        const val KEY_USER = "user"
        const val KEY_ALIAS = "septena-session-key"
    }
}
