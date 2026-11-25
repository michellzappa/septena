package app.septena.android.doing

import android.icu.text.MeasureFormat
import android.icu.util.Measure
import android.icu.util.MeasureUnit
import app.septena.android.ui.localizedPlural
import app.septena.android.ui.registryText
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.longValue
import app.septena.core.stringValue
import java.util.Locale

/** The words and lengths of Do (surfaces.json `doing`, docs/DO_SPEC.md §3 to §5). */
internal class DoCopy(private val languageTag: String) {
    private val surface = RegistryCatalog.surface(RegistrySurfaceIds.DOING)

    /** The lengths offered, in minutes. */
    val lengths: List<Int>
        get() = (surface?.fields?.get("lengths") as? JsonValue.ArrayValue)?.values.orEmpty()
            .mapNotNull { it.longValue()?.toInt() }

    val lastTimeTitle: String get() = text("screen", "lastTime", "title")
    val firstStepTitle: String get() = text("screen", "firstStep", "title")
    val lengthTitle: String get() = text("screen", "length", "title")
    val noLengthTitle: String get() = text("screen", "length", "noneTitle", "title")
    val stopNoteTitle: String get() = text("stopNote", "title")
    val stopNoteSave: String get() = text("stopNote", "confirmTitle")
    val stopNoteSkip: String get() = text("stopNote", "dismissTitle")
    val openExit: String get() = text("openExit", "label")

    fun lengthOption(minutes: Int): String =
        text("screen", "length", "option", "format").replace("{count}", minutes.toString())

    fun notice(title: String): String = text("notice", "format").replace("{title}", title)

    fun stale(title: String): String = text("stale", "format").replace("{title}", title)

    fun plannedEnd(minutes: Int): String = plural("plannedEnd", minutes)

    fun needsYou(count: Int): String = plural("needsYou", count)

    /** The label of an exit (`doExit`) in the history. */
    fun exit(exit: String): String = text("exits", exit, "label")

    /** `12 min`, in the user's language. Whole minutes only. */
    fun length(minutes: Long): String {
        val format = MeasureFormat.getInstance(Locale.forLanguageTag(languageTag), MeasureFormat.FormatWidth.SHORT)
        val rest = Measure(minutes % 60, MeasureUnit.MINUTE)
        return if (minutes < 60) format.formatMeasures(rest)
        else format.formatMeasures(Measure(minutes / 60, MeasureUnit.HOUR), rest)
    }

    private fun text(vararg path: String): String = registryText(node(*path).stringValue(), languageTag)

    private fun plural(key: String, count: Int): String {
        val forms = (node(key, "format") as? JsonValue.ObjectValue)?.fields.orEmpty()
        val other = forms["other"].stringValue().orEmpty()
        return localizedPlural(other, forms["one"].stringValue() ?: other, other, count, languageTag)
    }

    private fun node(vararg path: String): JsonValue? {
        var value: JsonValue? = surface
        for (key in path) value = (value as? JsonValue.ObjectValue)?.fields?.get(key)
        return value
    }
}
