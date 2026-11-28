package app.septena.core

import app.septena.core.generated.RegistryRules
import java.io.File

/** Runs `registry/shell-conformance/navigation-history.json` against [NavigationHistory] (#849). */
class NavigationHistoryTest {
    fun conformanceVectors() {
        val fixture = JsonValue.parse(File("../../registry/shell-conformance/navigation-history.json").readText())
            .asObject()
        val cases = fixture.arrayAt("cases")
        check(cases.isNotEmpty()) { "navigation-history.json has no cases" }
        for (value in cases) {
            val case = value.asObject()
            val name = case.requiredString("name")
            val history = NavigationHistory<String>(
                case.longAt("limit")?.toInt() ?: RegistryRules.NAVIGATION_HISTORY_LIMIT.toInt(),
            )
            val removed = mutableSetOf<String>()
            val exists: (String) -> Boolean = { it !in removed }
            case.arrayAt("steps").forEachIndexed { index, stepValue ->
                val step = stepValue.asObject()
                when (val op = step.requiredString("op")) {
                    "visit" -> history.visit(step.requiredString("entry"))
                    "back" -> assertEquals(step.stringAt("expect"), history.goBack(exists), "$name: step $index")
                    "forward" -> assertEquals(step.stringAt("expect"), history.goForward(exists), "$name: step $index")
                    "remove" -> removed += step.requiredString("entry")
                    else -> error("$name: unknown op $op")
                }
            }
            val expected = case.objectAt("expected")
            assertEquals(expected.stringAt("current"), history.current, "$name: current")
            assertEquals(expected.stringListAt("back"), history.back, "$name: back")
            assertEquals(expected.stringListAt("forward"), history.forward, "$name: forward")
        }
        println("NavigationHistory: ${cases.size} cases passed")
    }

    fun limitComesFromTheRegistry() {
        assertEquals(50, NavigationHistory<String>().limit, "default limit")
    }
}
