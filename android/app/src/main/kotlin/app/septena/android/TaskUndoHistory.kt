package app.septena.android

import app.septena.core.JsonValue
import app.septena.core.SyncRecord
import app.septena.core.TaskMutator
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

/** One process-wide undo stack for task edits made from any Android surface. */
class TaskUndoHistory {
    private sealed interface UndoOperation {
        data class RestoreFields(val fields: Map<String, JsonValue>) : UndoOperation
        data object RestoreDeleted : UndoOperation
        data object DeleteRestored : UndoOperation
        data object DeleteCreated : UndoOperation
    }

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

    /** Called by a foreground gesture after its mutator write succeeds. */
    suspend fun recordEdit(before: SyncRecord?, after: SyncRecord?) {
        recordEdits(listOf(before to after))
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

    private fun step(before: SyncRecord?, after: SyncRecord?): Step? {
        if (before == null || after == null ||
            before.entity != RegistryEntityNames.TASK || after.entity != RegistryEntityNames.TASK
        ) return null

        val operation = when {
            before.deletedAt == null && after.deletedAt != null -> UndoOperation.RestoreDeleted
            before.deletedAt != null && after.deletedAt == null -> UndoOperation.DeleteRestored
            before.deletedAt != null || after.deletedAt != null -> return null
            else -> {
                val changedFields = (before.fields.keys + after.fields.keys)
                    .filter { before.fields[it] != after.fields[it] }
                if (changedFields.isEmpty()) return null
                UndoOperation.RestoreFields(
                    changedFields.associateWith { field -> before.fields[field] ?: JsonValue.Null },
                )
            }
        }
        return Step(taskId = before.id, operation = operation)
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
    suspend fun undo(mutator: TaskMutator): Boolean = mutex.withLock {
        val entry = entries.lastOrNull() ?: return@withLock false
        var undone = false
        for (step in entry.steps.asReversed()) {
            val replayed = when (val operation = step.operation) {
                is UndoOperation.RestoreFields -> mutator.updateFields(step.taskId, operation.fields) != null
                UndoOperation.RestoreDeleted -> mutator.restore(step.taskId) != null
                UndoOperation.DeleteRestored,
                UndoOperation.DeleteCreated -> mutator.delete(step.taskId) != null
            }
            undone = undone || replayed
        }
        if (!undone) return@withLock false

        entries.removeAt(entries.lastIndex)
        mutableState.value = mutableState.value.copy(canUndo = entries.isNotEmpty())
        true
    }
}
