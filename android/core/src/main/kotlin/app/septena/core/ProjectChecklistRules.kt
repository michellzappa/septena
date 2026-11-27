package app.septena.core

import app.septena.sharedcore.invokeJson

object ProjectChecklistRules {
    data class Group(val id: String, val items: List<String>)
    data class Layout(
        val ungrouped: List<String>,
        val groups: List<Group>,
        val checked: List<String>,
        val matches: List<String>,
        val suggestedGroup: String?,
    )

    fun layout(rows: List<SyncRecord>, query: String = ""): Layout {
        val output = call(
            "projectChecklist",
            mapOf(
                "rows" to JsonValue.ArrayValue(rows.map { row ->
                    JsonValue.ObjectValue(row.fields + ("id" to JsonValue.StringValue(row.id)))
                }),
                "query" to JsonValue.StringValue(query),
                "groceries" to JsonValue.BooleanValue(query.isNotBlank()),
            ),
        )
        return Layout(
            ungrouped = ids(output["ungrouped"]),
            groups = (output["groups"] as JsonValue.ArrayValue).values.map { value ->
                val group = (value as JsonValue.ObjectValue).fields
                Group(requireNotNull(group["id"].stringValue()), ids(group["items"]))
            },
            checked = ids(output["checked"]),
            matches = ids(output["matches"]),
            suggestedGroup = output["suggestedGroup"].stringValue(),
        )
    }

    fun patch(checked: Boolean): Map<String, JsonValue> =
        call("checklistCheckPatch", mapOf("checked" to JsonValue.BooleanValue(checked)))

    private fun ids(value: JsonValue?): List<String> =
        (value as JsonValue.ArrayValue).values.map { requireNotNull(it.stringValue()) }

    private fun call(name: String, fields: Map<String, JsonValue>): Map<String, JsonValue> {
        val input = JsonValue.ObjectValue(fields).canonicalJson()
        val result = (JsonValue.parse(invokeJson(name, input)) as JsonValue.ObjectValue).fields
        check(result["error"] == null) { result["error"].stringValue().orEmpty() }
        return result
    }
}
