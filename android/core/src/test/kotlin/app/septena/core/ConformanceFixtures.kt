package app.septena.core

import java.io.File
import kotlin.contracts.ExperimentalContracts
import kotlin.contracts.contract

internal object ConformanceFixtures {
    fun load(name: String): JsonValue.ObjectValue =
        JsonValue.parse(File("../../registry/conformance/$name").readText()) as JsonValue.ObjectValue
}

internal fun JsonValue.asObject(): JsonValue.ObjectValue =
    this as? JsonValue.ObjectValue ?: error("Expected JSON object")

internal fun JsonValue.asArray(): List<JsonValue> =
    (this as? JsonValue.ArrayValue)?.values ?: error("Expected JSON array")

internal fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue =
    fields[key]?.asObject() ?: error("Expected object at '$key'")

internal fun JsonValue.ObjectValue.arrayAt(key: String): List<JsonValue> =
    fields[key]?.asArray() ?: error("Expected array at '$key'")

internal fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

internal fun JsonValue.ObjectValue.requiredString(key: String): String =
    stringAt(key) ?: error("Expected string at '$key'")

internal fun JsonValue.ObjectValue.longAt(key: String): Long? = when (val value = fields[key]) {
    is JsonValue.IntegerValue -> value.value
    is JsonValue.DecimalValue -> value.value.takeIf { it % 1.0 == 0.0 }?.toLong()
    else -> null
}

internal fun JsonValue.ObjectValue.requiredLong(key: String): Long =
    longAt(key) ?: error("Expected integer at '$key'")

internal fun JsonValue.ObjectValue.booleanAt(key: String): Boolean? = fields[key].booleanValue()

internal fun JsonValue.ObjectValue.requiredBoolean(key: String): Boolean =
    booleanAt(key) ?: error("Expected boolean at '$key'")

internal fun JsonValue.ObjectValue.stringListAt(key: String): List<String>? =
    (fields[key] as? JsonValue.ArrayValue)?.values?.map { value ->
        value.stringValue() ?: error("Expected string in '$key'")
    }

internal fun JsonValue.ObjectValue.integerListAt(key: String): List<Int>? =
    (fields[key] as? JsonValue.ArrayValue)?.values?.map { value ->
        (value as? JsonValue.IntegerValue)?.value?.toInt() ?: error("Expected integer in '$key'")
    }

internal fun JsonValue.ObjectValue.without(vararg keys: String): Map<String, JsonValue> =
    fields - keys.toSet()

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
