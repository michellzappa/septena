package app.septena.core

import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class TaskUndoState(
    val canUndo: Boolean = false,
    /** Changes only when a new user edit is recorded, so the shell can announce it once. */
    val latestEditId: Long = 0,
)

/** One undo stack for task edits across the current workspace's surfaces. */
class TaskUndoHistory {
    private sealed interface UndoOperation {
        data class RestoreFields(val fields: Map<String, JsonValue>) : UndoOperation
        data class RestoreConvoFields(val fields: Map<String, JsonValue>) : UndoOperation
        data object RestoreDeleted : UndoOperation
        data object DeleteRestored : UndoOperation
        data object DeleteCreated : UndoOperation
        /** A non-task row the gesture created (a project from the area page, #706). */
        data class DeleteCreatedEntity(val entity: String) : UndoOperation
    }

    /** One task around a gesture's write, with its conversation when the gesture may change that too. */
    data class Edit(
        val taskId: String,
        val beforeTask: SyncRecord?,
        val afterTask: SyncRecord?,
        val beforeConvo: SyncRecord?,
        val afterConvo: SyncRecord?,
    )

    private data class Step(
        val taskId: String,
        val operation: UndoOperation,
    )

    /** One user gesture. A batch action on a selection is one entry with a step per task. */
    private data class Entry(val steps: List<Step>)

    private val mutex = Mutex()
    private val entries = mutableListOf<Entry>()
    private val mutableState = MutableStateFlow(TaskUndoState())

    val state: StateFlow<TaskUndoState> = mutableState

    /**
     * Records task + conversation mutations (such as Review Accept or Send back)
     * as ONE undo entry so Undo restores both the task and the conversation state.
     */
    suspend fun recordTaskAndConvoEdits(edits: List<Edit>) {
        val steps = edits.flatMap { edit ->
            listOfNotNull(
                step(edit.beforeTask, edit.afterTask),
                convoStep(edit.taskId, edit.beforeConvo, edit.afterConvo),
            )
        }
        if (steps.isEmpty()) return
        record(Entry(steps))
    }

    /**
     * Records the edits of one gesture on several tasks as ONE undo step, so
     * Undo after a batch action on a selection restores every task at once.
     */
    suspend fun recordEdits(edits: List<Pair<SyncRecord?, SyncRecord?>>) {
        val steps = edits.mapNotNull { (before, after) -> step(before, after) }
        if (steps.isEmpty()) return
        record(Entry(steps))
    }

    /** Called after a user gesture creates a task, so Undo can remove that copy. */
    suspend fun recordCreated(task: SyncRecord) {
        if (task.entity != RegistryEntityNames.TASK || task.deletedAt != null) return
        record(Entry(listOf(Step(taskId = task.id, operation = UndoOperation.DeleteCreated))))
    }

    /** Called after a user gesture creates a non-task row (a project), so Undo can remove it. */
    suspend fun recordCreatedEntity(created: SyncRecord) {
        if (created.entity == RegistryEntityNames.TASK || created.deletedAt != null) return
        record(Entry(listOf(Step(taskId = created.id, operation = UndoOperation.DeleteCreatedEntity(created.entity)))))
    }

    private fun step(before: SyncRecord?, after: SyncRecord?): Step? {
        if (before == null || after == null ||
            before.entity != RegistryEntityNames.TASK || after.entity != RegistryEntityNames.TASK
        ) return null

        val operation = when {
            before.deletedAt == null && after.deletedAt != null -> UndoOperation.RestoreDeleted
            before.deletedAt != null && after.deletedAt == null -> UndoOperation.DeleteRestored
            before.deletedAt != null || after.deletedAt != null -> return null
            else -> {
                val fields = restorationFields(RegistryEntityNames.TASK, before.fields, after.fields)
                if (fields.isEmpty()) return null
                UndoOperation.RestoreFields(fields)
            }
        }
        return Step(taskId = before.id, operation = operation)
    }

    private fun convoStep(taskId: String, before: SyncRecord?, after: SyncRecord?): Step? {
        if (after == null || after.entity != RegistryEntityNames.CONVO) return null
        val fields = restorationFields(RegistryEntityNames.CONVO, before?.fields.orEmpty(), after.fields)
        if (fields.isEmpty()) return null
        return Step(taskId, UndoOperation.RestoreConvoFields(fields))
    }

    private fun restorationFields(
        entity: String,
        before: Map<String, JsonValue>,
        after: Map<String, JsonValue>,
    ): Map<String, JsonValue> {
        val spec = RegistryEntities.all.getValue(entity)
        return buildMap {
            for (field in before.keys + after.keys) {
                if (before[field] == after[field]) continue
                val column = spec.columns[field] ?: continue
                if (column.serverOwned || spec.updatable?.contains(field) == false) continue
                val repeatMode = if (entity == RegistryEntityNames.TASK && field == RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION) {
                    RecurrenceRules.fromFields(before)?.let { JsonValue.BooleanValue(it.afterCompletion) }
                } else null
                val missingValue = if (column.nullable == true) JsonValue.Null else null
                val value = before[field] ?: repeatMode ?: column.defaultFieldValue() ?: missingValue
                if (value != null) put(field, value)
            }
        }
    }

    /** Drops every entry: the tasks they restore are gone (account deletion). */
    suspend fun clear() {
        mutex.withLock {
            entries.clear()
            mutableState.value = mutableState.value.copy(canUndo = false)
        }
    }

    private suspend fun record(entry: Entry) {
        mutex.withLock {
            entries += entry
            mutableState.value = TaskUndoState(
                canUndo = true,
                latestEditId = mutableState.value.latestEditId + 1,
            )
        }
    }

    /**
     * Replays the newest user gesture through the normal mutator, newest step
     * first. The entry stays available when no step could be replayed.
     */
    suspend fun undo(
        mutator: TaskMutator,
        conversationMutator: ConversationMutator? = null,
        entityMutator: RegistryEntityMutator? = null,
    ): Boolean = mutex.withLock {
        val entry = entries.lastOrNull() ?: return@withLock false
        var undone = false
        for (step in entry.steps.asReversed()) {
            val replayed = when (val operation = step.operation) {
                is UndoOperation.RestoreFields -> mutator.updateFields(step.taskId, operation.fields) != null
                is UndoOperation.RestoreConvoFields -> runCatching {
                    conversationMutator?.update(step.taskId, operation.fields) != null
                }.getOrDefault(false)
                UndoOperation.RestoreDeleted -> mutator.restore(step.taskId) != null
                UndoOperation.DeleteRestored,
                UndoOperation.DeleteCreated -> mutator.delete(step.taskId) != null
                is UndoOperation.DeleteCreatedEntity -> runCatching {
                    entityMutator?.delete(operation.entity, step.taskId) != null
                }.getOrDefault(false)
            }
            undone = undone || replayed
        }
        if (!undone) return@withLock false

        entries.removeAt(entries.lastIndex)
        mutableState.value = mutableState.value.copy(canUndo = entries.isNotEmpty())
        true
    }
}
