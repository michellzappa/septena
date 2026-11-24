package app.septena.android

import android.content.Context
import app.septena.store.SqlDelightTaskStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Wipes the deleted account's data from this device: every local row, turn, outbox entry and shadow, the
 * attachment files and the undo stack. The wipe is marked pending on disk before it starts. While it is
 * pending, the next launch tries again and no sign-in is stored ([app.septena.android.auth.AppCredentials]),
 * so the old rows can never reach another account.
 */
class AccountWipe(
    context: Context,
    private val store: SqlDelightTaskStore,
    private val attachments: TaskAttachmentStore,
    private val undoHistory: TaskUndoHistory,
) {
    private val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val mutex = Mutex()

    fun markPending() {
        preferences.edit().putBoolean(KEY_PENDING, true).commit()
    }

    /** Runs a pending wipe; true when one ran. Throws, and stays pending, when a part of it fails. */
    suspend fun finishIfPending(): Boolean = mutex.withLock {
        if (!preferences.getBoolean(KEY_PENDING, false)) return@withLock false
        store.wipeAllLocalData()
        undoHistory.clear()
        check(attachments.wipeLocalFiles()) { "Could not delete the attachment files" }
        preferences.edit().remove(KEY_PENDING).commit()
        true
    }

    private companion object {
        const val PREFS = "septena-account-wipe"
        const val KEY_PENDING = "pending"
    }
}

/**
 * Deletes the account on the backend (`DELETE /v1/account`), then wipes this device ([AccountWipe]) and
 * forgets the session. Same order as iOS (`TaskSyncEngine.deleteAccount`): sync pauses first, so that no push
 * in flight writes rows back after the server emptied the store. When the server does not confirm, nothing
 * local changes, sync runs again, and the error is thrown. Once it confirms, this never throws: the account
 * is gone, and a wipe that fails stays pending. Afterwards the device starts over at the first run, because
 * Android has no signed-out task list to return to.
 */
suspend fun AndroidAppGraph.deleteAccount() {
    sync.pause()
    try {
        taskBackend.deleteAccount()
    } catch (error: Exception) {
        sync.resume()
        throw error
    }
    accountWipe.markPending()
    // The task screens still collect the data version, so they drop the old rows before they leave.
    runCatching { finishPendingWipe() }
    credentials.forgetSession()
    firstRun.startOver()
    sync.resume()
}
