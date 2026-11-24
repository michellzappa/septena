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

    private data class Entry(
        val taskId: String,
        val operation: UndoOperation,
    )

    private val mutex = Mutex()
    private val entries = mutableListOf<Entry>()
    private val mutableState = MutableStateFlow(TaskUndoState())

    val state: StateFlow<TaskUndoState> = mutableState

    /** Called by a foreground gesture after its mutator write succeeds. */
    suspend fun recordEdit(before: SyncRecord?, after: SyncRecord?) {
        if (before == null || after == null ||
            before.entity != RegistryEntityNames.TASK || after.entity != RegistryEntityNames.TASK
        ) return

        val operation = when {
            before.deletedAt == null && after.deletedAt != null -> UndoOperation.RestoreDeleted
            before.deletedAt != null && after.deletedAt == null -> UndoOperation.DeleteRestored
            before.deletedAt != null || after.deletedAt != null -> return
            else -> {
                val changedFields = (before.fields.keys + after.fields.keys)
                    .filter { before.fields[it] != after.fields[it] }
                if (changedFields.isEmpty()) return
                UndoOperation.RestoreFields(
                    changedFields.associateWith { field -> before.fields[field] ?: JsonValue.Null },
                )
            }
        }

        record(Entry(taskId = before.id, operation = operation))
    }

    /** Called after a user gesture creates a task, so Undo can remove that copy. */
    suspend fun recordCreated(task: SyncRecord) {
        if (task.entity != RegistryEntityNames.TASK || task.deletedAt != null) return
        record(Entry(taskId = task.id, operation = UndoOperation.DeleteCreated))
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

    /** Replays the newest user edit through the normal mutator and leaves failed entries available. */
    suspend fun undo(mutator: TaskMutator): Boolean = mutex.withLock {
        val entry = entries.lastOrNull() ?: return@withLock false
        val undone = when (val operation = entry.operation) {
            is UndoOperation.RestoreFields -> mutator.updateFields(entry.taskId, operation.fields) != null
            UndoOperation.RestoreDeleted -> mutator.restore(entry.taskId) != null
            UndoOperation.DeleteRestored,
            UndoOperation.DeleteCreated -> mutator.delete(entry.taskId) != null
        }
        if (!undone) return@withLock false

        entries.removeAt(entries.lastIndex)
        mutableState.value = mutableState.value.copy(canUndo = entries.isNotEmpty())
        true
    }
}
