package app.septena.android.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The account-switch rule (#575), the same as Apple `TaskSyncEngine.signIn`. */
class AccountSwitchRulesTest {
    private var counted = false
    private fun summary(tasks: Int, unsent: Int): () -> AccountSwitchSummary = {
        counted = true
        AccountSwitchSummary(tasks, unsent)
    }

    @Test
    fun sameAccountAdoptsWithoutCounting() {
        val decision = AccountSwitchRules.decide("user-a", "user-a", summary(3, 1))
        assertEquals(AccountSwitchDecision.Adopt, decision)
        assertFalse(counted)
    }

    @Test
    fun unknownLastAccountKeepsTheLocalData() {
        val decision = AccountSwitchRules.decide(null, "user-b", summary(3, 1))
        assertEquals(AccountSwitchDecision.Adopt, decision)
        assertFalse(counted)
    }

    @Test
    fun anotherAccountWithNothingLocalWipesWithoutAsking() {
        val decision = AccountSwitchRules.decide("user-a", "user-b", summary(0, 0))
        assertEquals(AccountSwitchDecision.WipeAndAdopt, decision)
        assertTrue(counted)
    }

    @Test
    fun anotherAccountWithTasksAsks() {
        val decision = AccountSwitchRules.decide("user-a", "user-b", summary(2, 0))
        assertEquals(AccountSwitchDecision.Ask(AccountSwitchSummary(2, 0)), decision)
    }

    @Test
    fun anotherAccountWithOnlyUnsentChangesAsks() {
        val decision = AccountSwitchRules.decide("user-a", "user-b", summary(0, 4))
        assertEquals(AccountSwitchDecision.Ask(AccountSwitchSummary(0, 4)), decision)
    }
}
