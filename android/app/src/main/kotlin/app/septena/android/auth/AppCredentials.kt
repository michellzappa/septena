package app.septena.android.auth

import app.septena.transport.SeptenaAuthClient
import app.septena.transport.SessionTokens
import app.septena.transport.SyncCredentials
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException

/**
 * Supplies access tokens to the sync transport. The server keeps a refresh token good until the one
 * that replaces it is used (ADR 0040), so the new one is stored before its access token is used. Every
 * refresh runs under one mutex, and a caller that waited re-uses the token the previous holder fetched.
 */
class AppCredentials(
    private val store: SessionStore,
    private val auth: SeptenaAuthClient,
    private val nowMs: () -> Long = System::currentTimeMillis,
    /** Must succeed before a new session is stored: the wipe of a deleted account, when one is pending. */
    private val beforeAdopt: suspend () -> Unit = {},
) : SyncCredentials {
    private val mutex = Mutex()
    @Volatile private var access: String? = null
    @Volatile private var accessExpiresAtMs: Long = 0L

    private val _signedIn = MutableStateFlow(store.load() != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()

    /** Signed-in backend user id for Settings ▸ Account (#565), or null when signed out. */
    private val _userId = MutableStateFlow(store.load()?.userId)
    val userId: StateFlow<String?> = _userId.asStateFlow()

    suspend fun adopt(tokens: SessionTokens) {
        beforeAdopt()
        mutex.withLock { remember(tokens) }
    }

    override suspend fun accessToken(): String? {
        val current = access
        if (current != null && nowMs() < accessExpiresAtMs - EXPIRY_MARGIN_MS) return current
        return refresh(stale = current)
    }

    override suspend fun refreshAfterUnauthorized(): String? = refresh(stale = access)

    suspend fun signOut() {
        val saved = mutex.withLock {
            val saved = store.load()
            store.clear()
            access = null
            accessExpiresAtMs = 0L
            _signedIn.value = false
            _userId.value = null
            saved
        }
        saved?.let { runCatching { auth.signOut(it.refreshToken) } }
    }

    /**
     * Forgets the session on this device without a sign-out call: after account deletion the server's
     * store is empty, so the refresh token fails its next rotation anyway (same as iOS).
     */
    suspend fun forgetSession() = mutex.withLock {
        store.clear()
        access = null
        accessExpiresAtMs = 0L
        _signedIn.value = false
        _userId.value = null
    }

    private suspend fun refresh(stale: String?): String? = mutex.withLock {
        val current = access
        if (current != null && current != stale && nowMs() < accessExpiresAtMs - EXPIRY_MARGIN_MS) return current
        val saved = store.load() ?: run {
            _signedIn.value = false
            _userId.value = null
            return null
        }
        val tokens = auth.refresh(saved.refreshToken)
        if (tokens == null) {
            store.clear()
            access = null
            _signedIn.value = false
            _userId.value = null
            return null
        }
        remember(tokens)
        tokens.accessToken
    }

    private fun remember(tokens: SessionTokens) {
        if (!store.save(tokens.refreshToken, tokens.userId)) throw IOException("The session was not stored")
        access = tokens.accessToken
        accessExpiresAtMs = nowMs() + tokens.expiresInSeconds * 1000L
        _signedIn.value = true
        _userId.value = tokens.userId
    }

    private companion object {
        const val EXPIRY_MARGIN_MS = 60_000L
    }
}
