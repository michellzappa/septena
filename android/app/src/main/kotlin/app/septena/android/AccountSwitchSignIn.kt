package app.septena.android

import app.septena.android.auth.AccountSwitchChoice
import app.septena.android.auth.AccountSwitchDecision
import app.septena.android.auth.AccountSwitchRules
import app.septena.android.auth.AccountSwitchSummary
import app.septena.core.generated.RegistryEntityNames
import app.septena.transport.SessionTokens
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * Stores a new session, and protects the local data when it belongs to another account (#575). Same rule as
 * Apple `TaskSyncEngine.signIn`: another user id with tasks or unsent changes on this device asks [confirm].
 * Replace wipes the device ([AccountWipe], as account deletion does), then stores the session. Cancel and
 * Export a Backup First keep the local data and revoke the new session. With nothing local, another account
 * wipes without asking.
 *
 * Sync pauses for the whole call, so the old outbox can never push with the new session, and no sync runs
 * between the wipe and the stored session. Returns null when the session is stored, or the user's answer
 * when it is not. Throws when the wipe or the store fails: then no session is stored and the new one is
 * revoked.
 */
suspend fun AndroidAppGraph.signIn(
    tokens: SessionTokens,
    confirm: suspend (AccountSwitchSummary) -> AccountSwitchChoice,
): AccountSwitchChoice? {
    sync.pause()
    try {
        // A deleted account's pending wipe runs first, so the summary never counts its rows.
        finishPendingWipe()
        val decision = AccountSwitchRules.decide(credentials.lastUserId(), tokens.userId) { accountSwitchSummary() }
        val replaces = when (decision) {
            AccountSwitchDecision.Adopt -> false
            AccountSwitchDecision.WipeAndAdopt -> true
            is AccountSwitchDecision.Ask -> {
                val choice = try {
                    confirm(decision.summary)
                } catch (cancelled: CancellationException) {
                    withContext(NonCancellable) { revoke(tokens) }
                    throw cancelled
                }
                if (choice != AccountSwitchChoice.Replace) {
                    revoke(tokens)
                    return choice
                }
                true
            }
        }
        try {
            if (replaces) replaceLocalAccountData()
            credentials.adopt(tokens)
        } catch (error: Exception) {
            withContext(NonCancellable) { revoke(tokens) }
            throw error
        }
        return null
    } finally {
        sync.resume()
    }
}

/** What a switch would remove: every task row on this device (trash included, as Apple) and the outbox. */
private suspend fun AndroidAppGraph.accountSwitchSummary() = AccountSwitchSummary(
    tasks = taskStore.records(RegistryEntityNames.TASK).size,
    unsent = taskStore.outboxCount(),
)

/**
 * The account-deletion wipe, for another account's data. It is marked pending first: when a part fails, it
 * throws and stays pending, and [app.septena.android.auth.AppCredentials.adopt] stores no session until it ran.
 */
private suspend fun AndroidAppGraph.replaceLocalAccountData() {
    accountWipe.markPending()
    finishPendingWipe()
    forgetAccountScopedState()
}

/** Ends a session this device does not keep. A failed call only leaves a token that nobody holds. */
private suspend fun AndroidAppGraph.revoke(tokens: SessionTokens) {
    runCatching { auth.signOut(tokens.refreshToken) }
}
