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
    private data class Entry(
        val taskId: String,
        val before: Map<String, JsonValue>,
    )

    private val mutex = Mutex()
    private val entries = mutableListOf<Entry>()
    private val mutableState = MutableStateFlow(TaskUndoState())

    val state: StateFlow<TaskUndoState> = mutableState

    /** Called by a foreground gesture after its mutator write succeeds. */
    suspend fun recordEdit(before: SyncRecord?, after: SyncRecord?) {
        if (before == null || after == null ||
            before.entity != RegistryEntityNames.TASK || after.entity != RegistryEntityNames.TASK ||
            before.deletedAt != null || after.deletedAt != null
        ) return

        val changedFields = (before.fields.keys + after.fields.keys)
            .filter { before.fields[it] != after.fields[it] }
        if (changedFields.isEmpty()) return

        val inverse = changedFields.associateWith { field -> before.fields[field] ?: JsonValue.Null }
        mutex.withLock {
            entries += Entry(taskId = before.id, before = inverse)
            mutableState.value = TaskUndoState(
                canUndo = true,
                latestEditId = mutableState.value.latestEditId + 1,
            )
        }
    }

    /** Replays the newest user edit through the normal mutator and leaves failed entries available. */
    suspend fun undo(mutator: TaskMutator): Boolean = mutex.withLock {
        val entry = entries.lastOrNull() ?: return@withLock false
        if (mutator.updateFields(entry.taskId, entry.before) == null) return@withLock false

        entries.removeAt(entries.lastIndex)
        mutableState.value = mutableState.value.copy(canUndo = entries.isNotEmpty())
        true
    }
}
