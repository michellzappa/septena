package app.septena.store

/** Runs the shared store conformance vectors without adding a test framework dependency. */
object StoreConformanceTestRunner {
    @JvmStatic
    fun main(args: Array<String>) {
        val tests = SyncEngineStoreConformanceTest()
        tests.pulledRowVectors()
        tests.remoteAttachmentDeleteNotifiesListener()
        println("Store conformance vectors passed")
    }
}
