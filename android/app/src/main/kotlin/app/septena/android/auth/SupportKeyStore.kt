package app.septena.android.auth

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

/**
 * The Contact Support key (ADR 0054): 32 random bytes, base64url without padding (43 characters),
 * made once and kept sealed on this device. A signed-out sender's conversation is keyed by its hash
 * on the backend. Same role as Apple's Keychain entry `com.septena.support.key`.
 */
class SupportKeyStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val sealer = KeystoreSealer(KEY_ALIAS)

    @Synchronized
    fun key(): String {
        sealer.open(prefs.getString(KEY_SUPPORT, null))?.takeIf { it.length == KEY_LENGTH }?.let { return it }
        val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
        val key = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
        prefs.edit().putString(KEY_SUPPORT, sealer.seal(key)).commit()
        return key
    }

    private companion object {
        const val PREFS = "septena-support"
        const val KEY_SUPPORT = "key"
        const val KEY_ALIAS = "septena-support-key"
        const val KEY_LENGTH = 43
    }
}
