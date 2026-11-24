package app.septena.android

/**
 * Deletes the account on the backend (`DELETE /v1/account`), then wipes this device: every local row, turn,
 * outbox entry and shadow, the attachment files, the undo stack and the session. Same order as iOS
 * (`TaskSyncEngine.deleteAccount`): sync pauses first, so that no push in flight writes rows back after the
 * server emptied the store. When the server does not confirm, nothing local changes, sync runs again, and the
 * error is thrown. Once it confirms, the session always goes, even if a local delete fails: the caller must
 * not report "nothing was deleted" then. Afterwards the device starts over at the first run, because Android
 * has no signed-out task list to return to.
 */
suspend fun AndroidAppGraph.deleteAccount() {
    sync.pause()
    try {
        taskBackend.deleteAccount()
    } catch (error: Exception) {
        sync.resume()
        throw error
    }
    try {
        taskStore.wipeAllLocalData()
        // The task screens still collect this, so they drop the old rows before they leave the screen.
        sync.noteLocalChange()
        attachments.wipeLocalFiles()
        taskUndoHistory.clear()
    } finally {
        credentials.forgetSession()
        firstRun.startOver()
        sync.resume()
    }
}
