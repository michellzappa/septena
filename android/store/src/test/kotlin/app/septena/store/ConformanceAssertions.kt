package app.septena.store

import kotlin.contracts.ExperimentalContracts
import kotlin.contracts.contract

internal fun <T> assertEquals(expected: T, actual: T, message: String? = null) {
    if (expected != actual) {
        throw AssertionError("${message?.let { "$it: " }.orEmpty()}expected <$expected>, got <$actual>")
    }
}

internal fun assertTrue(actual: Boolean, message: String? = null) {
    if (!actual) throw AssertionError(message ?: "Expected condition to be true")
}

@OptIn(ExperimentalContracts::class)
internal fun <T : Any> assertNotNull(actual: T?, message: String? = null): T {
    contract { returns() implies (actual != null) }
    return actual ?: throw AssertionError(message ?: "Expected a non-null value")
}

internal fun assertNull(actual: Any?, message: String? = null) {
    if (actual != null) throw AssertionError("${message?.let { "$it: " }.orEmpty()}expected null, got <$actual>")
}

internal inline fun <reified T : Throwable> assertFailsWith(
    message: String? = null,
    block: () -> Unit,
): T {
    try {
        block()
    } catch (failure: Throwable) {
        if (failure is T) return failure
        throw AssertionError(
            "${message?.let { "$it: " }.orEmpty()}expected ${T::class.java.name}, got ${failure::class.java.name}",
            failure,
        )
    }
    throw AssertionError("${message?.let { "$it: " }.orEmpty()}expected ${T::class.java.name} to be thrown")
}
