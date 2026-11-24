package app.septena.store

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import app.septena.core.JsonValue
import app.septena.core.SyncChange
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncRecord
import app.septena.core.SyncResultStatus
import app.septena.core.SyncWireCodec
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.stringValue
import app.septena.store.db.SeptenaDatabase
import java.io.File
import java.time.Instant
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

class SyncEngineStoreConformanceTest {
    fun pulledRowVectors() {
        val fixture = load("sync-engine.json")
        for (caseValue in fixture.arrayAt("pullRow")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val expected = case.objectAt("expected")
            val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
            try {
                SeptenaDatabase.Schema.create(driver)
                val database = SeptenaDatabase(driver)
                val store = SqlDelightTaskStore(database)
                val entity = input.requiredString("entity")
                val targetRow = input.objectAt("row")
                val rowId = targetRow.stringAt("id") ?: when (entity) {
                    "turn" -> targetRow.stringAt("taskId") ?: "task-vector-1"
                    else -> "vector-row-1"
                }
                val current = input.objectOrNull("current")

                runSuspending {
                    if (current != null) {
                        val initialRow = current.fields + mapOf(
                            "id" to JsonValue.StringValue(rowId),
                            "rev" to JsonValue.IntegerValue(1),
                        )
                        store.applyPullPage(
                            SyncPullPage(
                                changes = listOf(SyncChange(entity, initialRow)),
                                nextSince = 1,
                                hasMore = false,
                            ),
                            Instant.parse("2026-11-21T12:00:00Z"),
                        )
                    }

                    val record = store.record(entity, rowId)
                    if (input.booleanAt("pendingDelete") == true && record != null) {
                        store.writeLocalAndEnqueue(
                            record.copy(deletedAt = "2026-11-21T12:00:00Z"),
                            SyncOperation.Delete("pending-delete-1", entity, rowId),
                        )
                    } else {
                        val pendingFields = input.stringListAt("pendingFields").orEmpty()
                        if (record != null && pendingFields.isNotEmpty()) {
                            val changes = pendingFields.associateWith { field ->
                                record.fields[field] ?: error("Missing local field '$field'")
                            }
                            store.writeLocalAndEnqueue(
                                record,
                                SyncOperation.Upsert("pending-upsert-1", entity, rowId, changes),
                            )
                        }
                    }

                }

                val targetPage = SyncPullPage(
                    changes = listOf(SyncChange(entity, targetRow.fields)),
                    nextSince = 2,
                    hasMore = false,
                )
                val expectedError = expected.stringAt("error")
                if (expectedError != null) {
                    val failure = assertFailsWith<IllegalStateException>(case.requiredString("name")) {
                        runSuspending {
                            store.applyPullPage(targetPage, Instant.parse("2026-11-21T12:00:01Z"))
                        }
                    }
                    assertEquals(expectedError, failure.message, case.requiredString("name"))
                    continue
                }
                runSuspending { store.applyPullPage(targetPage, Instant.parse("2026-11-21T12:00:01Z")) }

                val plan = expected.requiredString("plan")
                when (plan) {
                    "turn" -> {
                        val turns = runSuspending {
                            store.turns(expected.requiredString("taskId"))
                        }
                        assertEquals(1, turns.size, case.requiredString("name"))
                        assertEquals(expected.requiredLong("seq"), turns.single().sequence, case.requiredString("name"))
                        assertEquals(
                            expected.objectAt("row").fields,
                            turns.single().fields,
                            case.requiredString("name"),
                        )
                    }
                    "skip" -> {
                        assertEquals(current?.fields, runSuspending { store.record(entity, rowId)?.fields })
                    }
                    "shadowOnly" -> {
                        assertEquals(
                            current?.fields,
                            runSuspending { store.record(entity, rowId)?.fields },
                            case.requiredString("name"),
                        )
                        assertShadow(database, entity, rowId, expected, case.requiredString("name"))
                    }
                    "merge" -> {
                        val record = runSuspending { store.record(entity, rowId) }
                        assertNotNull(record, case.requiredString("name"))
                        assertEquals(expected.objectAt("fields").fields, record.fields, case.requiredString("name"))
                        if (expected.fields.containsKey("revision")) {
                            assertEquals(expected.longAt("revision"), record.revision, case.requiredString("name"))
                        }
                        if (expected.fields.containsKey("updatedAt")) {
                            assertEquals(expected.stringAt("updatedAt"), record.updatedAt, case.requiredString("name"))
                        }
                        assertShadow(database, entity, rowId, expected, case.requiredString("name"))
                    }
                    "tombstone" -> {
                        val keepLocal = expected.booleanAt("keepLocalRow") ?: false
                        val record = runSuspending { store.record(entity, rowId) }
                        if (keepLocal) {
                            assertNotNull(record, case.requiredString("name"))
                            assertEquals(targetRow.stringAt("deletedAt"), record.deletedAt, case.requiredString("name"))
                            if (input.stringListAt("pendingFields").orEmpty().isNotEmpty()) {
                                val rejected = runSuspending { store.notSyncedOperations() }.single()
                                assertEquals(false, rejected.retryable, case.requiredString("name"))
                            }
                        } else {
                            assertNull(record, case.requiredString("name"))
                        }
                        assertShadow(database, entity, rowId, expected, case.requiredString("name"))
                    }
                    else -> error("Unknown pull row plan '$plan'")
                }
                if (plan != "error") assertEquals(2, runSuspending { store.syncCursor() }, case.requiredString("name"))
            } finally {
                driver.close()
            }
        }
    }

    fun remoteAttachmentDeleteNotifiesListener() {
        val driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        try {
            SeptenaDatabase.Schema.create(driver)
            val store = SqlDelightTaskStore(SeptenaDatabase(driver))
            val deleted = mutableListOf<Pair<String, String>>()
            store.onRemoteDelete = { entity, id -> deleted += entity to id }
            val now = Instant.parse("2026-11-24T12:00:00Z")

            runSuspending {
                // Pull a live attachment and a live task: neither fires onRemoteDelete.
                store.applyPullPage(
                    SyncPullPage(
                        changes = listOf(
                            SyncChange(
                                RegistryEntityNames.ATTACHMENT,
                                mapOf(
                                    "id" to JsonValue.StringValue("att-1"),
                                    "rev" to JsonValue.IntegerValue(1),
                                    "taskId" to JsonValue.StringValue("task-1"),
                                    "filename" to JsonValue.StringValue("photo.jpg"),
                                    "contentType" to JsonValue.StringValue("image/jpeg"),
                                    "byteCount" to JsonValue.IntegerValue(128),
                                    "position" to JsonValue.DecimalValue(0.0),
                                    "createdAt" to JsonValue.StringValue("2026-11-24T11:00:00Z"),
                                ),
                            ),
                            SyncChange(
                                RegistryEntityNames.TASK,
                                mapOf(
                                    "id" to JsonValue.StringValue("task-1"),
                                    "rev" to JsonValue.IntegerValue(1),
                                    "title" to JsonValue.StringValue("Keep me"),
                                    "status" to JsonValue.StringValue("open"),
                                ),
                            ),
                        ),
                        nextSince = 1,
                        hasMore = false,
                    ),
                    now,
                )
                assertEquals(emptyList<Pair<String, String>>(), deleted, "live pull must not fire onRemoteDelete")

                // Pull tombstones for both: attachment fires onRemoteDelete, task keeps its local row.
                store.applyPullPage(
                    SyncPullPage(
                        changes = listOf(
                            SyncChange(
                                RegistryEntityNames.ATTACHMENT,
                                mapOf(
                                    "id" to JsonValue.StringValue("att-1"),
                                    "rev" to JsonValue.IntegerValue(2),
                                    "deletedAt" to JsonValue.StringValue("2026-11-24T12:00:00Z"),
                                ),
                            ),
                            SyncChange(
                                RegistryEntityNames.TASK,
                                mapOf(
                                    "id" to JsonValue.StringValue("task-1"),
                                    "rev" to JsonValue.IntegerValue(2),
                                    "deletedAt" to JsonValue.StringValue("2026-11-24T12:00:00Z"),
                                ),
                            ),
                        ),
                        nextSince = 2,
                        hasMore = false,
                    ),
                    now,
                )
                assertEquals(
                    listOf(RegistryEntityNames.ATTACHMENT to "att-1"),
                    deleted,
                    "attachment tombstone fires onRemoteDelete; task tombstone does not",
                )
                assertNull(store.record(RegistryEntityNames.ATTACHMENT, "att-1"), "attachment row removed")

                // A DROPPED push result for an attachment also fires onRemoteDelete.
                val att2Fields = mapOf(
                    "taskId" to JsonValue.StringValue("task-2"),
                    "filename" to JsonValue.StringValue("doc.pdf"),
                    "contentType" to JsonValue.StringValue("application/pdf"),
                    "byteCount" to JsonValue.IntegerValue(256),
                    "position" to JsonValue.DecimalValue(0.0),
                    "createdAt" to JsonValue.StringValue("2026-11-24T11:00:00Z"),
                )
                store.writeLocalAndEnqueue(
                    SyncRecord(RegistryEntityNames.ATTACHMENT, "att-2", att2Fields),
                    SyncOperation.Upsert("op-att-2", RegistryEntityNames.ATTACHMENT, "att-2", att2Fields),
                )
                store.applyPushResults(
                    listOf(SyncOperationResult("op-att-2", SyncResultStatus.DROPPED, revision = 3)),
                    now,
                )
                assertEquals(
                    listOf(RegistryEntityNames.ATTACHMENT to "att-1", RegistryEntityNames.ATTACHMENT to "att-2"),
                    deleted,
                    "dropped attachment push fires onRemoteDelete",
                )
                assertNull(store.record(RegistryEntityNames.ATTACHMENT, "att-2"), "dropped attachment row removed")

                // A reset pull must never invoke onRemoteDelete.
                deleted.clear()
                store.resetForFullPull()
                assertEquals(emptyList<Pair<String, String>>(), deleted, "resetForFullPull must not fire onRemoteDelete")
            }
        } finally {
            driver.close()
        }
    }
}

private fun assertShadow(
    database: SeptenaDatabase,
    entity: String,
    id: String,
    expected: JsonValue.ObjectValue,
    caseName: String,
) {
    val shadow = database.syncQueries.selectAllShadows().executeAsList().singleOrNull {
        it.entity == entity && it.id == id
    }
    assertNotNull(shadow, caseName)
    assertEquals(expected.objectAt("shadow").fields, parseObject(shadow.fieldsJson), caseName)
    if (expected.fields.containsKey("revision")) {
        assertEquals(expected.longAt("revision"), shadow.revision, caseName)
    }
    if (expected.fields.containsKey("plan") && expected.requiredString("plan") == "tombstone") {
        assertTrue(shadow.gone == 1L, caseName)
    }
}

private fun parseObject(json: String): Map<String, JsonValue> =
    (JsonValue.parse(json) as JsonValue.ObjectValue).fields

private fun load(name: String): JsonValue.ObjectValue =
    JsonValue.parse(File("../../registry/conformance/$name").readText()) as JsonValue.ObjectValue

private fun JsonValue.asObject(): JsonValue.ObjectValue =
    this as? JsonValue.ObjectValue ?: error("Expected JSON object")

private fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue =
    fields[key]?.asObject() ?: error("Expected object at '$key'")

private fun JsonValue.ObjectValue.objectOrNull(key: String): JsonValue.ObjectValue? =
    fields[key] as? JsonValue.ObjectValue

private fun JsonValue.ObjectValue.arrayAt(key: String): List<JsonValue> =
    (fields[key] as? JsonValue.ArrayValue)?.values ?: error("Expected array at '$key'")

private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

private fun JsonValue.ObjectValue.requiredString(key: String): String =
    stringAt(key) ?: error("Expected string at '$key'")

private fun JsonValue.ObjectValue.longAt(key: String): Long? = when (val value = fields[key]) {
    is JsonValue.IntegerValue -> value.value
    else -> null
}

private fun JsonValue.ObjectValue.requiredLong(key: String): Long =
    longAt(key) ?: error("Expected integer at '$key'")

private fun JsonValue.ObjectValue.booleanAt(key: String): Boolean? = fields[key].booleanValue()

private fun JsonValue.ObjectValue.stringListAt(key: String): List<String>? =
    (fields[key] as? JsonValue.ArrayValue)?.values?.map { value ->
        value.stringValue() ?: error("Expected string in '$key'")
    }

private fun <T> runSuspending(block: suspend () -> T): T {
    var result: Result<T>? = null
    val latch = java.util.concurrent.CountDownLatch(1)
    block.startCoroutine(object : Continuation<T> {
        override val context = EmptyCoroutineContext
        override fun resumeWith(value: Result<T>) {
            result = value
            latch.countDown()
        }
    })
    check(latch.await(10, java.util.concurrent.TimeUnit.SECONDS)) { "Suspending operation did not complete" }
    return result!!.getOrThrow()
}
