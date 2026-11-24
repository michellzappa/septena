package app.septena.core

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
        }
        SyncEngineConformanceTest().run {
            pullPageVectors()
            pushResponseVectors()
            rejectionReasonVectors()
        }
        // Every fixture once more through the core's own runner, as loaded here
        // (JNA + the release's natives): proves the Kotlin bindings link.
        val failures = File("../../registry/conformance").listFiles { f -> f.extension == "json" }!!
            .sortedBy { it.name }
            .flatMap { file ->
                val report = runConformance(file.nameWithoutExtension, file.readText())
                println("core ${report.fixture}: ${report.cases} cases, ${report.failures.size} failed")
                report.failures
            }
        check(failures.isEmpty()) { "Core conformance failures:\n" + failures.joinToString("\n") }
        println("Core conformance vectors passed")
    }
}
