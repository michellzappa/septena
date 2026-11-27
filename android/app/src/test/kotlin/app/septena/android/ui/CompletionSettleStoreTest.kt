package app.septena.android.ui

import app.septena.core.generated.RegistryCompletionMotion
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionSettleStoreTest {
    @Test
    fun registryTokensMatchStandardTimings() {
        assertEquals(3000L, RegistryCompletionMotion.SETTLE_DELAY_MS)
        assertEquals(350, RegistryCompletionMotion.FADE_OUT_MS)
        assertEquals(280, RegistryCompletionMotion.CHECK_POP_MS)
        assertEquals(400, RegistryCompletionMotion.PULSE_RING_MS)
    }

    @Test
    fun settlesFadesAndClearsInOrder() = runBlocking {
        val store = CompletionSettleStore(this, settleDelayMs = 60L, fadeOutMs = 60L)
        store.start("t1", reviewGroupId = "finished")
        assertTrue(store.state.value.isSettling("t1"))
        assertFalse(store.state.value.isFadingOut("t1"))
        assertEquals("finished", store.state.value.entries["t1"]?.reviewGroupId)

        delay(90L)
        assertTrue(store.state.value.isSettling("t1"))
        assertTrue(store.state.value.isFadingOut("t1"))

        delay(90L)
        assertFalse(store.state.value.isSettling("t1"))
        assertFalse(store.state.value.isFadingOut("t1"))
    }

    @Test
    fun cancelAbortsFadeOut() = runBlocking {
        val store = CompletionSettleStore(this, settleDelayMs = 60L, fadeOutMs = 60L)
        store.start("t1")
        delay(20L)
        store.cancel("t1")
        assertFalse(store.state.value.isSettling("t1"))
        delay(140L)
        assertFalse(store.state.value.isSettling("t1"))
    }
}
