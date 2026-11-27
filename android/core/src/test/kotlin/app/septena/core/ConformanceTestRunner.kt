package app.septena.core

import app.septena.sharedcore.CoreException
import app.septena.sharedcore.runConformance
import java.io.File

/** Runs the shared conformance vectors without adding a test framework dependency. */
object ConformanceTestRunner {
    @JvmStatic
    fun main(args: Array<String>) {
        RegistryConformanceTest().run {
            recurrenceVectors()
            reminderVectors()
            taskFadeVectors()
            taskViewVectors()
            conversationVectors()
            taskPageBlocksVectors()
        }
        ReviewGroupTest().run {
            registryOrder()
            waitingOrder()
        }
        StructureOrderTest().run {
            positionZeroAndNullSinkToBottom()
            allUnpositionedFallsBackToCaseInsensitiveAlphabetical()
            tiedPositionsBreakByTitle()
            nextAppendPositionAndReorderAreOneBased()
        }
        SyncEngineConformanceTest().run {
            pullPageVectors()
            pushResponseVectors()
            rejectionReasonVectors()
        }
        FixedRepeatRescheduleConformanceTest().runAll()
        // Every fixture once more through the core's own runner, as loaded here
        // (JNA + the release's natives): proves the Kotlin bindings link.
        val failures = File("../../registry/conformance").listFiles { f -> f.extension == "json" }!!
            .sortedBy { it.name }
            .flatMap { file ->
                // A fixture lands before the release that runs it
                // (core/release/README.md); core.yml runs it in every artifact.
                val report = try {
                    runConformance(file.nameWithoutExtension, file.readText())
                } catch (e: CoreException.InvalidInput) {
                    if (!e.reason.startsWith("The core has no runner for")) throw e
                    println("core ${file.nameWithoutExtension}: the pinned core is older than this fixture, skipped")
                    return@flatMap emptyList()
                }
                println("core ${report.fixture}: ${report.cases} cases, ${report.failures.size} failed")
                report.failures
            }
        check(failures.isEmpty()) { "Core conformance failures:\n" + failures.joinToString("\n") }
        println("Core conformance vectors passed")
    }
}
