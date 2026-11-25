package app.septena.core

/** One line of notes as a page shows them while nobody edits them. */
sealed interface NotesPreviewLine {
    data class Heading(val level: Int, val text: String) : NotesPreviewLine
    data object Blank : NotesPreviewLine

    /** A list item: its nesting depth, its marker ("•", "☐", "☑", "1.") and text. */
    data class Item(val depth: Int, val marker: String, val text: String) : NotesPreviewLine
    data class Quote(val text: String) : NotesPreviewLine
    data class Body(val text: String) : NotesPreviewLine
}

/** Project and area notes as read (Apple `ContainerNotes.previewLines`; keep the two in step). */
object PlaceNotes {
    private val heading = Regex("""^(#{1,6})[ \t]+(.*)$""")
    private val task = Regex("""^[-*+]\s+\[([ xX])]\s+(.*)$""")
    private val bullet = Regex("""^[-*+]\s+(.*)$""")
    private val numbered = Regex("""^(\d+[.)])\s+(.*)$""")
    private val quote = Regex("""^>\s?(.*)$""")

    fun previewLines(raw: String): List<NotesPreviewLine> {
        val source = raw.replace("\r\n", "\n").split("\n").map(::previewLine)

        // A heading with nothing under it (an unfilled template section) drops.
        val kept = source.filterIndexed { index, line ->
            if (line !is NotesPreviewLine.Heading) return@filterIndexed true
            when (val next = source.drop(index + 1).firstOrNull { it != NotesPreviewLine.Blank }) {
                null -> false
                is NotesPreviewLine.Heading -> next.level > line.level
                else -> true
            }
        }

        val result = mutableListOf<NotesPreviewLine>()
        kept.forEach { line ->
            val last = result.lastOrNull()
            val drops = line == NotesPreviewLine.Blank &&
                (last == null || last == NotesPreviewLine.Blank || last is NotesPreviewLine.Heading)
            if (!drops) result += line
        }
        while (result.lastOrNull() == NotesPreviewLine.Blank) result.removeAt(result.lastIndex)
        return result
    }

    private fun previewLine(line: String): NotesPreviewLine {
        val content = line.trim()
        if (content.isEmpty()) return NotesPreviewLine.Blank
        heading.find(content)?.let {
            return NotesPreviewLine.Heading(it.groupValues[1].length, it.groupValues[2].trim())
        }
        val depth = (line.takeWhile { it == ' ' || it == '\t' }.length / 2).coerceAtMost(4)
        task.find(content)?.let {
            val marker = if (it.groupValues[1] == " ") "☐" else "☑"
            return NotesPreviewLine.Item(depth, marker, it.groupValues[2])
        }
        bullet.find(content)?.let { return NotesPreviewLine.Item(depth, "•", it.groupValues[1]) }
        numbered.find(content)?.let { return NotesPreviewLine.Item(depth, it.groupValues[1], it.groupValues[2]) }
        quote.find(content)?.let { return NotesPreviewLine.Quote(it.groupValues[1]) }
        return NotesPreviewLine.Body(content)
    }
}
