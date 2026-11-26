package app.septena.android.auth

import android.content.Context

/** What a sign-in with another account removes from this device (#575): the tasks and the unsent changes. */
data class AccountSwitchSummary(val tasks: Int, val unsent: Int) {
    val isEmpty: Boolean get() = tasks == 0 && unsent == 0
}

/** The user's answer to the account-switch question. Same three answers as Apple (`AccountSwitchChoice`). */
enum class AccountSwitchChoice { Cancel, ExportFirst, Replace }

/** What a new session needs before it is stored. */
sealed interface AccountSwitchDecision {
    /** The same account, or no account known on this device: keep the local data. */
    data object Adopt : AccountSwitchDecision

    /** Another account, and nothing local to lose: wipe without asking. */
    data object WipeAndAdopt : AccountSwitchDecision

    /** Another account, and the device has tasks or unsent changes: ask the user. */
    data class Ask(val summary: AccountSwitchSummary) : AccountSwitchDecision
}

/** The account-switch rule, with no I/O. Same rule as Apple `TaskSyncEngine.signIn`. */
object AccountSwitchRules {
    /**
     * [summary] runs only for another account, so a sign-in with the same account never counts the store.
     * No stored id (the first sign-in on this device, or a session from a build before this check) keeps
     * the local data, as on Apple.
     */
    inline fun decide(
        lastUserId: String?,
        newUserId: String,
        summary: () -> AccountSwitchSummary,
    ): AccountSwitchDecision {
        if (lastUserId == null || lastUserId == newUserId) return AccountSwitchDecision.Adopt
        val counts = summary()
        return if (counts.isEmpty) AccountSwitchDecision.WipeAndAdopt else AccountSwitchDecision.Ask(counts)
    }
}

/**
 * The user id of the last session stored on this device. Sign-out does not clear it, so the next sign-in
 * can tell another account from the same one. Account deletion clears it: the wipe already removed that
 * account's data, so there is nothing to ask about.
 */
class LastAccountStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(): String? = prefs.getString(KEY_USER, null)

    fun save(userId: String) {
        if (prefs.getString(KEY_USER, null) == userId) return
        prefs.edit().putString(KEY_USER, userId).commit()
    }

    fun clear() {
        prefs.edit().remove(KEY_USER).commit()
    }

    private companion object {
        const val PREFS = "septena-last-account"
        const val KEY_USER = "user"
    }
}
