package app.septena.core

import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityPatterns

data class RegistryValidationIssue(val path: String, val reason: String)

class RegistryValidationException(val issues: List<RegistryValidationIssue>) :
    IllegalArgumentException(issues.joinToString { "${it.path}: ${it.reason}" })

/** Validates outgoing rows against the same generated schema the backend consumes. */
object RegistryValidator {
    fun validateId(id: String): List<RegistryValidationIssue> {
        val pattern = RegistryEntityPatterns.all.getValue("id")
        return if (Regex(pattern).matches(id)) emptyList()
        else listOf(RegistryValidationIssue("id", "does not match the registry id format"))
    }

    fun requireValidId(id: String) {
        val issues = validateId(id)
        if (issues.isNotEmpty()) throw RegistryValidationException(issues)
    }

    /**
     * [insert] is null when the caller cannot know: an outbox upsert can create
     * the row on the server or change it. Then the server checks the fields
     * that only an insert may set.
     */
    fun validateUpsert(
        entityName: String,
        id: String,
        fields: Map<String, JsonValue>,
        insert: Boolean?,
    ): List<RegistryValidationIssue> {
        val issues = mutableListOf<RegistryValidationIssue>()
        issues += validateId(id)

        val entity = RegistryEntities.all[entityName]
        if (entity == null) {
            return issues + RegistryValidationIssue("entity", "unknown entity '$entityName'")
        }

        if (insert == true) {
            for (required in entity.requiredOnInsert) {
                if (required !in fields) {
                    issues += RegistryValidationIssue("fields.$required", "required on insert")
                }
            }
        }

        for ((fieldName, value) in fields) {
            val path = "fields.$fieldName"
            val column = entity.columns[fieldName]
            if (column == null) {
                issues += RegistryValidationIssue(path, "field is not in the registry")
                continue
            }
            if (column.serverOwned) {
                issues += RegistryValidationIssue(path, "field is owned by the server")
                continue
            }
            if (insert == false && entity.updatable != null && fieldName !in entity.updatable) {
                issues += RegistryValidationIssue(path, "field is not updatable")
                continue
            }
            if (value === JsonValue.Null) {
                if (column.nullable != true) issues += RegistryValidationIssue(path, "null is not allowed")
                continue
            }

            val numeric = when (value) {
                is JsonValue.IntegerValue -> value.value.toDouble()
                is JsonValue.DecimalValue -> value.value
                else -> null
            }
            val typeMatches = when (column.kind) {
                "text" -> value is JsonValue.StringValue
                "int" -> numeric != null && numeric.isFinite() && numeric == numeric.toLong().toDouble()
                "real" -> numeric != null && numeric.isFinite()
                "bool" -> value is JsonValue.BooleanValue
                "json" -> true
                else -> false
            }
            if (!typeMatches) {
                issues += RegistryValidationIssue(path, "expected ${column.kind}")
                continue
            }

            if (value is JsonValue.StringValue) {
                val maxLength = column.max
                if (maxLength != null && value.value.length.toLong() > maxLength) {
                    issues += RegistryValidationIssue(path, "exceeds the maximum length of $maxLength")
                }
                val format = column.format
                if (format != null) {
                    val pattern = RegistryEntityPatterns.all[format]
                    if (pattern == null || !Regex(pattern).containsMatchIn(value.value)) {
                        issues += RegistryValidationIssue(path, "does not match registry format '$format'")
                    }
                }
                val enumName = column.enumName
                if (enumName != null && value.value !in RegistryEntityEnums.all[enumName].orEmpty()) {
                    issues += RegistryValidationIssue(path, "is not in registry enum '$enumName'")
                }
            }

            if (numeric != null) {
                val minimum = column.min
                if (minimum != null && numeric < minimum) {
                    issues += RegistryValidationIssue(path, "must be at least $minimum")
                }
                val maximum = column.max
                if (maximum != null && numeric > maximum.toDouble()) {
                    issues += RegistryValidationIssue(path, "must be at most $maximum")
                }
            }

            val maxJsonLength = column.maxJsonLength
            if (column.kind == "json" && maxJsonLength != null && value.canonicalJson().length.toLong() > maxJsonLength) {
                issues += RegistryValidationIssue(path, "exceeds the maximum JSON length of $maxJsonLength")
            }
        }

        if (entityName == "setting") {
            if ("value" !in fields) {
                issues += RegistryValidationIssue("fields.value", "required for a setting upsert")
            } else {
                issues += RegistrySettingsValidator.validate(id, fields.getValue("value"))
            }
        }

        return issues
    }

    fun requireValidUpsert(entityName: String, id: String, fields: Map<String, JsonValue>, insert: Boolean?) {
        val issues = validateUpsert(entityName, id, fields, insert)
        if (issues.isNotEmpty()) throw RegistryValidationException(issues)
    }
}
