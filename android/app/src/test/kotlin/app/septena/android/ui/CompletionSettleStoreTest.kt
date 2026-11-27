package app.septena.android.ui

import app.septena.core.generated.RegistryCompletionMotion
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class CompletionSettleStoreTest {
    @Test
    fun registryTokensMatchStandardTimings() {
        assertEquals(3000L, RegistryCompletionMotion.SETTLE_DELAY_MS)
        assertEquals(350, RegistryCompletionMotion.FADE_OUT_MS)
        assertEquals(280, RegistryCompletionMotion.CHECK_POP_MS)
        assertEquals(400, RegistryCompletionMotion.PULSE_RING_MS)
    }

    @Test
    fun settlesFadesAndClearsInOrder() = runTest {
        val store = CompletionSettleStore(this, settleDelayMs = 3000L, fadeOutMs = 350L)
        store.start("t1", reviewGroupId = "finished")
        assertTrue(store.state.value.isSettling("t1"))
        assertFalse(store.state.value.isFadingOut("t1"))
        assertEquals("finished", store.state.value.entries["t1"]?.reviewGroupId)

        advanceTimeBy(2999L)
        runCurrent()
        assertTrue(store.state.value.isSettling("t1"))
        assertFalse(store.state.value.isFadingOut("t1"))

        advanceTimeBy(1L)
        runCurrent()
        assertTrue(store.state.value.isSettling("t1"))
        assertTrue(store.state.value.isFadingOut("t1"))

        advanceTimeBy(350L)
        runCurrent()
        assertFalse(store.state.value.isSettling("t1"))
        assertFalse(store.state.value.isFadingOut("t1"))
    }

    @Test
    fun cancelAbortsFadeOut() = runTest {
        val store = CompletionSettleStore(this, settleDelayMs = 3000L, fadeOutMs = 350L)
        store.start("t1")
        advanceTimeBy(1000L)
        store.cancel("t1")
        assertFalse(store.state.value.isSettling("t1"))
        advanceTimeBy(5000L)
        runCurrent()
        assertFalse(store.state.value.isSettling("t1"))
    }
}
