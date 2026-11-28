package app.septena.core

import app.septena.sharedcore.invokeJson

/** Checklist projects (#860, docs/PROJECT_CHECKLIST_SPEC.md): the core's rules, called as-is. */
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
                // Grocery grouping applies to every Checklist (#860 decision 2).
                "groceries" to JsonValue.BooleanValue(true),
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

    /** What [heading] returns: the heading to use (null: ungrouped) and whether to create it first. */
    data class HeadingDecision(val heading: String?, val create: Boolean)

    /**
     * The one stable heading of suggested [group] in [projectId] (core
     * `checklistHeading`). [rows] are the project's headings, deleted ones
     * included, so a group the user removed is not created again.
     */
    fun heading(projectId: String, group: String, title: String, rows: List<SyncRecord>): HeadingDecision {
        val output = call(
            "checklistHeading",
            mapOf(
                "projectId" to JsonValue.StringValue(projectId),
                "group" to JsonValue.StringValue(group),
                "title" to JsonValue.StringValue(title),
                "rows" to JsonValue.ArrayValue(rows.map { row ->
                    val deleted = row.deletedAt?.let { JsonValue.StringValue(it) } ?: JsonValue.Null
                    JsonValue.ObjectValue(row.fields + mapOf("id" to JsonValue.StringValue(row.id), "deletedAt" to deleted))
                }),
            ),
        )
        return HeadingDecision(output["heading"].stringValue(), output["create"].booleanValue() == true)
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
