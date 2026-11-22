package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityPatterns
import java.time.DateTimeException
import java.time.ZoneId

/** Per-key setting validation generated from registry/settings.json metadata. */
object RegistrySettingsValidator {
    fun validate(key: String, value: JsonValue): List<RegistryValidationIssue> {
        val issues = mutableListOf<RegistryValidationIssue>()
        val definition = RegistryCatalog.setting(key)
            ?: return listOf(RegistryValidationIssue("id", "unknown synced setting '$key'"))
        if (definition.stringAt("scope") != "synced") {
            issues += RegistryValidationIssue("id", "device-only setting '$key' cannot be synced")
            return issues
        }
        if (value === JsonValue.Null) return issues

        val type = definition.stringAt("type")
        when (type) {
            "bool" -> if (value !is JsonValue.BooleanValue) issues += expected("boolean")
            "int" -> {
                val integer = (value as? JsonValue.IntegerValue)?.value
                if (integer == null) {
                    issues += expected("integer")
                } else {
                    val minimum = definition.numberAt("min")
                    val maximum = definition.numberAt("max")
                    if (minimum != null && integer < minimum) issues += RegistryValidationIssue("fields.value", "must be at least $minimum")
                    if (maximum != null && integer > maximum) issues += RegistryValidationIssue("fields.value", "must be at most $maximum")
                }
            }
            "string" -> {
                val text = (value as? JsonValue.StringValue)?.value
                if (text == null) {
                    issues += expected("string")
                } else {
                    val maxLength = definition.numberAt("maxLength")
                    if (maxLength != null && text.length.toLong() > maxLength) {
                        issues += RegistryValidationIssue("fields.value", "exceeds the maximum length of $maxLength")
                    }
                    definition.stringAt("format")?.let { format ->
                        val pattern = RegistryEntityPatterns.all[format]
                        if (pattern == null || !Regex(pattern).containsMatchIn(text)) {
                            issues += RegistryValidationIssue("fields.value", "does not match registry format '$format'")
                        }
                    }
                    if (key == "homeTimezone") {
                        try {
                            ZoneId.of(text)
                        } catch (_: DateTimeException) {
                            issues += RegistryValidationIssue("fields.value", "is not a valid time zone")
                        }
                    }
                }
            }
            "enum" -> {
                val text = (value as? JsonValue.StringValue)?.value
                val enumName = definition.stringAt("enum")
                val inlineValues = (definition.fields["values"] as? JsonValue.ArrayValue)
                    ?.values?.mapNotNull { it.stringValue() }
                val allowedValues = inlineValues ?: enumName?.let { RegistryEntityEnums.all[it] }
                if (text == null) {
                    issues += expected("string enum")
                } else if (allowedValues == null || text !in allowedValues) {
                    issues += RegistryValidationIssue("fields.value", "is not an allowed registry value")
                }
            }
            "string[]" -> {
                val values = (value as? JsonValue.ArrayValue)?.values
                if (values == null) {
                    issues += expected("array of strings")
                } else {
                    val maxItems = definition.numberAt("maxItems")
                    val itemMaxLength = definition.numberAt("itemMaxLength")
                    if (maxItems != null && values.size.toLong() > maxItems) {
                        issues += RegistryValidationIssue("fields.value", "contains more than $maxItems items")
                    }
                    values.forEachIndexed { index, item ->
                        val text = (item as? JsonValue.StringValue)?.value
                        if (text == null) {
                            issues += RegistryValidationIssue("fields.value[$index]", "expected string")
                        } else if (itemMaxLength != null && text.length.toLong() > itemMaxLength) {
                            issues += RegistryValidationIssue("fields.value[$index]", "exceeds the maximum length of $itemMaxLength")
                        }
                    }
                }
            }
            "record" -> {
                val entries = (value as? JsonValue.ObjectValue)?.fields
                if (entries == null) {
                    issues += expected("JSON object")
                } else {
                    val maxEntries = definition.numberAt("maxEntries")
                    val keyMaxLength = definition.numberAt("keyMaxLength")
                    val allowedValues = (definition.fields["values"] as? JsonValue.ArrayValue)
                        ?.values?.mapNotNull { it.stringValue() }?.toSet()
                    if (maxEntries != null && entries.size.toLong() > maxEntries) {
                        issues += RegistryValidationIssue("fields.value", "contains more than $maxEntries entries")
                    }
                    entries.forEach { (entryKey, entryVal) ->
                        if (keyMaxLength != null && entryKey.length.toLong() > keyMaxLength) {
                            issues += RegistryValidationIssue("fields.value.$entryKey", "key exceeds the maximum length of $keyMaxLength")
                        }
                        val text = (entryVal as? JsonValue.StringValue)?.value
                        if (text == null) {
                            issues += RegistryValidationIssue("fields.value.$entryKey", "expected string")
                        } else if (allowedValues != null && text !in allowedValues) {
                            issues += RegistryValidationIssue("fields.value.$entryKey", "is not an allowed registry value")
                        }
                    }
                }
            }
            else -> issues += RegistryValidationIssue("id", "setting '$key' has unsupported registry type '$type'")
        }
        return issues
    }

    private fun expected(type: String) = RegistryValidationIssue("fields.value", "expected $type")

    private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

    private fun JsonValue.ObjectValue.numberAt(key: String): Long? = when (val value = fields[key]) {
        is JsonValue.IntegerValue -> value.value
        is JsonValue.DecimalValue -> if (value.value % 1.0 == 0.0) value.value.toLong() else null
        else -> null
    }
}
