package app.septena.core

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
        println("Core conformance vectors passed")
    }
}
