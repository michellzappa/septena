package app.septena.core

/** JSON values used by the sync protocol without binding the shared core to Android or a JSON library. */
sealed interface JsonValue {
    data object Null : JsonValue
    data class BooleanValue(val value: Boolean) : JsonValue
    data class IntegerValue(val value: Long) : JsonValue
    data class DecimalValue(val value: Double) : JsonValue
    data class StringValue(val value: String) : JsonValue
    data class ArrayValue(val values: List<JsonValue>) : JsonValue
    data class ObjectValue(val fields: Map<String, JsonValue>) : JsonValue, Map<String, JsonValue> by fields

    fun canonicalJson(): String = when (this) {
        Null -> "null"
        is BooleanValue -> value.toString()
        is IntegerValue -> value.toString()
        is DecimalValue -> {
            require(value.isFinite()) { "JSON numbers must be finite" }
            if (value == value.toLong().toDouble() && kotlin.math.abs(value) < 9_007_199_254_740_992.0) {
                value.toLong().toString()
            } else {
                value.toString()
            }
        }
        is StringValue -> quoteJson(value)
        is ArrayValue -> values.joinToString(prefix = "[", postfix = "]", separator = ",") { it.canonicalJson() }
        is ObjectValue -> fields.toSortedMap().entries.joinToString(prefix = "{", postfix = "}", separator = ",") {
            "${quoteJson(it.key)}:${it.value.canonicalJson()}"
        }
    }

    companion object {
        fun stringOrNull(value: String?): JsonValue = value?.let(::StringValue) ?: Null
        fun integerOrNull(value: Long?): JsonValue = value?.let(::IntegerValue) ?: Null

        /** Strict JSON parser used by the generated registry documents and wire adapters. */
        fun parse(source: String): JsonValue = JsonParser(source).parse()
    }
}

fun JsonValue?.stringValue(): String? = (this as? JsonValue.StringValue)?.value

fun JsonValue?.booleanValue(): Boolean? = (this as? JsonValue.BooleanValue)?.value

/** A whole number, from an integer or an integral decimal. */
fun JsonValue?.longValue(): Long? = when (this) {
    is JsonValue.IntegerValue -> value
    is JsonValue.DecimalValue -> value.takeIf { it == kotlin.math.floor(it) }?.toLong()
    else -> null
}

private fun quoteJson(value: String): String = buildString(value.length + 2) {
    append('"')
    value.forEach { character ->
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000C' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20) {
                append("\\u")
                append(character.code.toString(16).padStart(4, '0'))
            } else {
                append(character)
            }
        }
    }
    append('"')
}

private class JsonParser(private val source: String) {
    private var index = 0

    fun parse(): JsonValue {
        val result = value()
        whitespace()
        require(index == source.length) { "Unexpected content after JSON value at offset $index" }
        return result
    }

    private fun value(): JsonValue {
        whitespace()
        require(index < source.length) { "Expected JSON value at end of input" }
        return when (source[index]) {
            'n' -> literal("null", JsonValue.Null)
            't' -> literal("true", JsonValue.BooleanValue(true))
            'f' -> literal("false", JsonValue.BooleanValue(false))
            '"' -> JsonValue.StringValue(string())
            '[' -> array()
            '{' -> objectValue()
            '-', in '0'..'9' -> number()
            else -> error("Unexpected JSON character '${source[index]}' at offset $index")
        }
    }

    private fun <T : JsonValue> literal(token: String, result: T): T {
        require(source.startsWith(token, index)) { "Expected '$token' at offset $index" }
        index += token.length
        return result
    }

    private fun array(): JsonValue.ArrayValue {
        index++
        whitespace()
        val values = mutableListOf<JsonValue>()
        if (consume(']')) return JsonValue.ArrayValue(values)
        while (true) {
            values += value()
            whitespace()
            if (consume(']')) return JsonValue.ArrayValue(values)
            require(consume(',')) { "Expected ',' or ']' at offset $index" }
        }
    }

    private fun objectValue(): JsonValue.ObjectValue {
        index++
        whitespace()
        val fields = linkedMapOf<String, JsonValue>()
        if (consume('}')) return JsonValue.ObjectValue(fields)
        while (true) {
            whitespace()
            require(index < source.length && source[index] == '"') { "Expected object key at offset $index" }
            val key = string()
            whitespace()
            require(consume(':')) { "Expected ':' after object key at offset $index" }
            fields[key] = value()
            whitespace()
            if (consume('}')) return JsonValue.ObjectValue(fields)
            require(consume(',')) { "Expected ',' or '}' at offset $index" }
        }
    }

    private fun string(): String {
        require(consume('"')) { "Expected string at offset $index" }
        val start = index
        // Fast path: scan unescaped strings directly and slice once without StringBuilder churn.
        while (index < source.length) {
            val character = source[index]
            if (character == '"') {
                val result = source.substring(start, index)
                index++
                return result
            }
            if (character == '\\') break
            if (character.code < 0x20) error("Unescaped control character in JSON string at offset $index")
            index++
        }
        return buildString(index - start + 16) {
            if (index > start) append(source, start, index)
            while (index < source.length) {
                val character = source[index++]
                when {
                    character == '"' -> return@buildString
                    character == '\\' -> {
                        require(index < source.length) { "Unfinished escape at end of JSON input" }
                        when (val escaped = source[index++]) {
                            '"', '\\', '/' -> append(escaped)
                            'b' -> append('\b')
                            'f' -> append('\u000C')
                            'n' -> append('\n')
                            'r' -> append('\r')
                            't' -> append('\t')
                            'u' -> append(unicodeEscape())
                            else -> error("Invalid string escape '\\$escaped' at offset ${index - 1}")
                        }
                    }
                    character.code < 0x20 -> error("Unescaped control character in JSON string at offset ${index - 1}")
                    else -> append(character)
                }
            }
            error("Unterminated JSON string")
        }
    }

    private fun unicodeEscape(): Char {
        require(index + 4 <= source.length) { "Incomplete unicode escape at offset $index" }
        val digits = source.substring(index, index + 4)
        val code = digits.toIntOrNull(16) ?: error("Invalid unicode escape at offset $index")
        index += 4
        return code.toChar()
    }

    private fun number(): JsonValue {
        val start = index
        consume('-')
        require(index < source.length) { "Incomplete number at end of JSON input" }
        if (!consume('0')) {
            require(source[index] in '1'..'9') { "Invalid number at offset $index" }
            while (index < source.length && source[index].isDigit()) index++
        }
        var fractional = false
        if (consume('.')) {
            fractional = true
            require(index < source.length && source[index].isDigit()) { "Expected fractional digits at offset $index" }
            while (index < source.length && source[index].isDigit()) index++
        }
        if (index < source.length && (source[index] == 'e' || source[index] == 'E')) {
            fractional = true
            index++
            if (index < source.length && (source[index] == '+' || source[index] == '-')) index++
            require(index < source.length && source[index].isDigit()) { "Expected exponent digits at offset $index" }
            while (index < source.length && source[index].isDigit()) index++
        }
        val raw = source.substring(start, index)
        if (!fractional) raw.toLongOrNull()?.let { return JsonValue.IntegerValue(it) }
        val decimal = raw.toDoubleOrNull() ?: error("Invalid JSON number '$raw'")
        require(decimal.isFinite()) { "JSON numbers must be finite" }
        return JsonValue.DecimalValue(decimal)
    }

    private fun whitespace() {
        while (index < source.length) {
            when (source[index]) {
                ' ', '\n', '\r', '\t' -> index++
                else -> return
            }
        }
    }

    private fun consume(character: Char): Boolean {
        if (index >= source.length || source[index] != character) return false
        index++
        return true
    }
}
