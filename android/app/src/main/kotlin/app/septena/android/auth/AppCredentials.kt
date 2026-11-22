package app.septena.android.auth

import app.septena.transport.SeptenaAuthClient
import app.septena.transport.SessionTokens
import app.septena.transport.SyncCredentials
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Supplies access tokens to the sync transport. Refresh tokens are single use, so every refresh runs
 * under one mutex, and a caller that waited re-uses the token the previous holder fetched.
 */
class AppCredentials(
    private val store: SessionStore,
    private val auth: SeptenaAuthClient,
    private val nowMs: () -> Long = System::currentTimeMillis,
) : SyncCredentials {
    private val mutex = Mutex()
    @Volatile private var access: String? = null
    @Volatile private var accessExpiresAtMs: Long = 0L

    private val _signedIn = MutableStateFlow(store.load() != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()

    suspend fun adopt(tokens: SessionTokens) = mutex.withLock { remember(tokens) }

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
            saved
        }
        saved?.let { runCatching { auth.signOut(it.refreshToken) } }
    }

    private suspend fun refresh(stale: String?): String? = mutex.withLock {
        val current = access
        if (current != null && current != stale && nowMs() < accessExpiresAtMs - EXPIRY_MARGIN_MS) return current
        val saved = store.load() ?: run {
            _signedIn.value = false
            return null
        }
        val tokens = auth.refresh(saved.refreshToken)
        if (tokens == null) {
            store.clear()
            access = null
            _signedIn.value = false
            return null
        }
        remember(tokens)
        tokens.accessToken
    }

    private fun remember(tokens: SessionTokens) {
        store.save(tokens.refreshToken, tokens.userId)
        access = tokens.accessToken
        accessExpiresAtMs = nowMs() + tokens.expiresInSeconds * 1000L
        _signedIn.value = true
    }

    private companion object {
        const val EXPIRY_MARGIN_MS = 60_000L
    }
}
