package app.septena.sharedcore.harness

import app.septena.sharedcore.CoreException
import app.septena.sharedcore.PullPageDecision
import app.septena.sharedcore.PullPageHeader
import app.septena.sharedcore.checkPullPage
import app.septena.sharedcore.occurrenceId
import app.septena.sharedcore.planPullRow
import app.septena.sharedcore.rowOpacity
import app.septena.sharedcore.runConformance
import java.io.File
import kotlin.math.abs
import kotlin.system.exitProcess

/**
 * Runs every registry/conformance/\*.json file through the packaged core and
 * calls a few typed functions, so records, sealed classes, nullables and
 * exceptions cross the Kotlin boundary. Argument: the fixture directory.
 */
fun main(args: Array<String>) {
    val files = File(args[0]).listFiles { f -> f.extension == "json" }.orEmpty().sortedBy { it.name }
    check(files.isNotEmpty()) { "no fixtures in ${args[0]}" }

    val failures = mutableListOf<String>()
    val times = mutableListOf<Double>()
    var cases = 0L
    for (file in files) {
        val fixture = file.nameWithoutExtension
        val json = file.readText()
        repeat(50) { round ->
            val start = System.nanoTime()
            val report = runConformance(fixture, json)
            times += (System.nanoTime() - start) / 1_000_000.0
            if (round == 0) {
                cases += report.cases.toLong()
                failures += report.failures.map { "$fixture: $it" }
            }
        }
    }

    check(occurrenceId("task-1", "2026-11-22") == "recur-27f6e5d56dadf4cc") { "occurrenceId" }
    check(abs(rowOpacity(0.5) - 0.775) < 1e-9) { "rowOpacity" }
    check(rowOpacity(null) == 1.0) { "rowOpacity(null)" }
    val page = checkPullPage(10L, PullPageHeader(resetRequired = false, nextSince = 20L, hasMore = true), 0u)
    check(page is PullPageDecision.ApplyAndContinue && page.nextCursor == 20L) { "checkPullPage: $page" }
    val threw = try {
        planPullRow("turn", "{\"seq\":1}", null, emptyList(), false)
        false
    } catch (_: CoreException) {
        true
    }
    check(threw) { "planPullRow should throw for a turn without taskId" }

    times.sort()
    val p95 = times[minOf(times.size - 1, (times.size * 0.95).toInt())]
    val os = System.getProperty("os.name").lowercase().replace(' ', '-')
    println("SEPTENA_CORE_METRICS platform=jvm-$os cases=$cases calls=${times.size} p95_ms_per_fixture=${"%.3f".format(p95)}")
    if (failures.isNotEmpty()) {
        failures.forEach(System.err::println)
        exitProcess(1)
    }
    if (p95 > 5.0) {
        System.err.println("p95 per fixture run is over the 5 ms budget")
        exitProcess(1)
    }
}
