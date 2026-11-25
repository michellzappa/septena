package app.septena.core

import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityPatterns
import app.septena.core.generated.RegistryTurnFields
import java.time.OffsetDateTime

/** JSON wire codec shared by the Android and future Windows transport adapters. */
object SyncWireCodec {
    fun encodePushBody(operations: List<SyncOperation>): String {
        require(operations.isNotEmpty()) { "The sync endpoint requires at least one operation" }
        require(operations.size <= RegistryEntityLimits.MAX_OPS_PER_PUSH.toInt()) {
            "Push exceeds the registry operation limit"
        }
        return JsonValue.ObjectValue(mapOf("ops" to JsonValue.ArrayValue(operations.map(::encodeOperation))))
            .canonicalJson()
    }

    fun encodeOperation(operation: SyncOperation): JsonValue.ObjectValue {
        require(Regex(RegistryEntityPatterns.clientOpId).matches(operation.clientOpId)) {
            "Invalid client operation id"
        }
        return when (operation) {
            is SyncOperation.Upsert -> {
                RegistryValidator.requireValidUpsert(operation.entity, operation.id, operation.fields, insert = null)
                val encoded = linkedMapOf<String, JsonValue>(
                    "clientOpId" to JsonValue.StringValue(operation.clientOpId),
                    "op" to JsonValue.StringValue("upsert"),
                    "entity" to JsonValue.StringValue(operation.entity),
                    "id" to JsonValue.StringValue(operation.id),
                    "fields" to JsonValue.ObjectValue(operation.fields),
                )
                operation.base?.let {
                    encoded["base"] = JsonValue.ObjectValue(mapOf("notes" to JsonValue.stringOrNull(it.notes)))
                }
                JsonValue.ObjectValue(encoded)
            }
            is SyncOperation.Delete -> {
                require(operation.entity in RegistryEntityNames.deletable) { "Entity '${operation.entity}' cannot be deleted" }
                RegistryValidator.requireValidId(operation.id)
                JsonValue.ObjectValue(linkedMapOf(
                    "clientOpId" to JsonValue.StringValue(operation.clientOpId),
                    "op" to JsonValue.StringValue("delete"),
                    "entity" to JsonValue.StringValue(operation.entity),
                    "id" to JsonValue.StringValue(operation.id),
                ))
            }
            is SyncOperation.AppendTurn -> {
                RegistryValidator.requireValidId(operation.taskId)
                validateTurn(operation.turn)
                JsonValue.ObjectValue(linkedMapOf(
                    "clientOpId" to JsonValue.StringValue(operation.clientOpId),
                    "op" to JsonValue.StringValue("appendTurn"),
                    "taskId" to JsonValue.StringValue(operation.taskId),
                    "turn" to JsonValue.ObjectValue(operation.turn),
                ))
            }
        }
    }

    fun decodeOperation(json: String): SyncOperation = decodeOperation(JsonValue.parse(json).requireObject("sync operation"))

    fun decodeOperation(value: JsonValue.ObjectValue): SyncOperation {
        val op = value.stringRequired("op")
        val clientOpId = value.stringRequired("clientOpId")
        return when (op) {
            "upsert" -> SyncOperation.Upsert(
                clientOpId = clientOpId,
                entity = value.stringRequired("entity"),
                id = value.stringRequired("id"),
                fields = value.objectRequired("fields").fields,
                base = value.objectAt("base")?.let { NotesBase(it.fields["notes"].stringValue()) },
            )
            "delete" -> SyncOperation.Delete(
                clientOpId = clientOpId,
                entity = value.stringRequired("entity"),
                id = value.stringRequired("id"),
            )
            "appendTurn" -> SyncOperation.AppendTurn(
                clientOpId = clientOpId,
                taskId = value.stringRequired("taskId"),
                turn = value.objectRequired("turn").fields,
            )
            else -> error("Unknown sync operation '$op'")
        }
    }

    fun decodePushResponse(json: String): SyncPushResponse {
        val root = JsonValue.parse(json).requireObject("push response")
        val results = root.arrayAt("results")?.map { raw ->
            val item = raw.requireObject("push result")
            SyncOperationResult(
                clientOpId = item.stringRequired("clientOpId"),
                status = SyncResultStatus.fromWire(item.stringRequired("status")),
                revision = item.longAt("rev"),
                sequence = item.longAt("seq"),
                reason = item.stringAt("reason"),
            )
        } ?: error("Push response is missing results")
        return SyncPushResponse(
            appliedThrough = root.longRequired("appliedThrough"),
            results = results,
        )
    }

    fun decodePullPage(json: String): SyncPullPage {
        val root = JsonValue.parse(json).requireObject("pull response")
        val changes = root.arrayAt("changes")?.map { raw ->
            val item = raw.requireObject("pull change")
            val entity = item.stringRequired("entity")
            require(entity == "turn" || entity in RegistryEntityNames.all) { "Unknown pulled entity '$entity'" }
            SyncChange(entity, item.objectRequired("row").fields)
        } ?: error("Pull response is missing changes")
        return SyncPullPage(
            resetRequired = root.booleanAt("resetRequired") == true,
            changes = changes,
            nextSince = root.longRequired("nextSince"),
            hasMore = root.booleanRequired("hasMore"),
        )
    }

    private fun JsonValue.requireObject(label: String): JsonValue.ObjectValue =
        this as? JsonValue.ObjectValue ?: error("Expected $label to be an object")

    private fun JsonValue.ObjectValue.stringRequired(key: String): String =
        stringAt(key) ?: error("Expected '$key' to be a string")

    private fun JsonValue.ObjectValue.longRequired(key: String): Long =
        longAt(key) ?: error("Expected '$key' to be an integer")

    private fun JsonValue.ObjectValue.booleanRequired(key: String): Boolean =
        booleanAt(key) ?: error("Expected '$key' to be a boolean")

    private fun JsonValue.ObjectValue.objectRequired(key: String): JsonValue.ObjectValue =
        objectAt(key) ?: error("Expected '$key' to be an object")

    private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

    private fun JsonValue.ObjectValue.longAt(key: String): Long? = when (val value = fields[key]) {
        is JsonValue.IntegerValue -> value.value
        else -> null
    }

    private fun JsonValue.ObjectValue.booleanAt(key: String): Boolean? = fields[key].booleanValue()

    private fun JsonValue.ObjectValue.arrayAt(key: String): List<JsonValue>? =
        (fields[key] as? JsonValue.ArrayValue)?.values

    private fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue? =
        fields[key] as? JsonValue.ObjectValue

    private fun validateTurn(turn: Map<String, JsonValue>) {
        require((turn.keys - RegistryTurnFields.all).isEmpty()) { "Turn contains fields outside the backend schema" }
        val role = turn["role"].stringValue()
        require(role != null && role in RegistryEntityEnums.all.getValue("convoTurnRole")) {
            "Turn role is not in the registry enum"
        }
        val step = turn["step"].stringValue()
        require(step != null && step in RegistryEntityEnums.all.getValue("convoTurnStep")) {
            "Turn step is not in the registry enum"
        }
        val timestamp = turn["ts"].stringValue()
        require(timestamp != null && runCatching { OffsetDateTime.parse(timestamp) }.isSuccess) {
            "Turn timestamp must include a UTC offset"
        }

        checkOptionalString(turn, "provider", RegistryEntityLimits.TURN_PROVIDER_MAX)
        checkOptionalString(turn, "question", RegistryEntityLimits.TURN_QUESTION_MAX)
        checkOptionalString(turn, "chosen", RegistryEntityLimits.TURN_CHOSEN_MAX)
        checkOptionalString(turn, "otherText", RegistryEntityLimits.TURN_OTHER_TEXT_MAX)
        checkOptionalString(turn, "note", RegistryEntityLimits.TURN_NOTE_MAX)

        when (val confidence = turn["confidence"]) {
            null, JsonValue.Null -> Unit
            is JsonValue.IntegerValue -> require(confidence.value in 0L..1L) { "Turn confidence must be in 0..1" }
            is JsonValue.DecimalValue -> require(confidence.value.isFinite() && confidence.value in 0.0..1.0) {
                "Turn confidence must be in 0..1"
            }
            else -> error("Turn confidence must be numeric or null")
        }

        when (val options = turn["options"]) {
            null, JsonValue.Null -> Unit
            is JsonValue.ArrayValue -> {
                require(options.values.size <= RegistryEntityLimits.TURN_MAX_OPTIONS) {
                    "Turn has more options than the registry allows"
                }
                options.values.forEachIndexed { index, value ->
                    val option = value.stringValue() ?: error("Turn option $index must be a string")
                    require(option.length.toLong() <= RegistryEntityLimits.TURN_OPTION_MAX) {
                        "Turn option $index exceeds the registry length limit"
                    }
                }
            }
            else -> error("Turn options must be an array of strings or null")
        }

        when (val reply = turn["inReplyTo"]) {
            null, JsonValue.Null -> Unit
            is JsonValue.IntegerValue -> require(reply.value > 0) { "Turn inReplyTo must be positive" }
            else -> error("Turn inReplyTo must be an integer or null")
        }
    }

    private fun checkOptionalString(turn: Map<String, JsonValue>, key: String, maxLength: Long) {
        when (val value = turn[key]) {
            null, JsonValue.Null -> Unit
            is JsonValue.StringValue -> require(value.value.length.toLong() <= maxLength) {
                "Turn $key exceeds the registry length limit"
            }
            else -> error("Turn $key must be a string or null")
        }
    }
}
