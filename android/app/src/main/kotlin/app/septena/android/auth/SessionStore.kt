package app.septena.android.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Persists the refresh token and user id, encrypted with an AES-GCM key held in the Android Keystore
 * (docs/ANDROID_CLIENT_SPEC.md §3). The access token stays in memory only.
 */
class SessionStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    data class Saved(val refreshToken: String, val userId: String)

    @Synchronized
    fun load(): Saved? {
        val refresh = decrypt(prefs.getString(KEY_REFRESH, null)) ?: return null
        val userId = prefs.getString(KEY_USER, null) ?: return null
        return Saved(refresh, userId)
    }

    /** False when the write failed: the previous session is still the stored one. */
    @Synchronized
    fun save(refreshToken: String, userId: String): Boolean {
        val oldRefresh = prefs.getString(KEY_REFRESH, null)
        val oldUser = prefs.getString(KEY_USER, null)
        // commit(), not apply(): the token must be on disk before its access token is used.
        if (prefs.edit().putString(KEY_REFRESH, encrypt(refreshToken)).putString(KEY_USER, userId).commit()) return true
        // A failed commit leaves the new values in memory. Memory must match the disk.
        prefs.edit().putString(KEY_REFRESH, oldRefresh).putString(KEY_USER, oldUser).commit()
        return false
    }

    @Synchronized
    fun clear() {
        prefs.edit().clear().commit()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    /** Null when the value is missing or cannot be decrypted (for example after a key reset): sign in again. */
    private fun decrypt(stored: String?): String? {
        if (stored == null) return null
        return runCatching {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_BYTES))
            cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES).toString(Charsets.UTF_8)
        }.getOrNull()
    }

    private companion object {
        const val PREFS = "septena-session"
        const val KEY_REFRESH = "refresh"
        const val KEY_USER = "user"
        const val KEY_ALIAS = "septena-session-key"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
