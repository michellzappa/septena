package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.septena.core.JsonValue
import app.septena.core.NotesPreviewLine
import app.septena.core.PlaceNotes
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.longValue
import app.septena.core.stringValue

/**
 * Project and area notes on the page. While nobody edits them: the notes as
 * read, folded to the registry's `placeNotes.previewLines` with Show more. A tap
 * on cut-off notes unfolds them, a tap on whole notes edits them (Apple
 * `ContainerNotesField`).
 */
@Composable
internal fun PlaceNotesField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    languageTag: String,
    focused: Boolean,
    onFocusedChange: (Boolean) -> Unit,
) {
    val surface = remember { RegistryCatalog.surface(RegistrySurfaceIds.PLACE_NOTES)?.fields.orEmpty() }
    val previewLines = surface["previewLines"].longValue()?.toInt() ?: 3
    fun copy(key: String): String =
        registryText((surface[key] as? JsonValue.ObjectValue)?.fields?.get("title").stringValue(), languageTag)

    val ink = MaterialTheme.colorScheme.onSurface
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    var editing by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    var cutOff by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    val preview = remember(value, ink, mutedInk) { renderNotes(value, ink, mutedInk) }

    LaunchedEffect(editing) { if (editing) focusRequester.requestFocus() }

    if (preview.isNotEmpty() && !editing && !focused) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = preview,
                fontSize = 14.5.sp,
                lineHeight = 20.sp,
                color = mutedInk,
                maxLines = if (expanded) Int.MAX_VALUE else previewLines,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { if (!expanded) cutOff = it.hasVisualOverflow },
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = label) {
                        if (cutOff && !expanded) expanded = true else editing = true
                    },
            )
            if (cutOff) {
                Text(
                    text = copy(if (expanded) "showLess" else "showMore"),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = mutedInk,
                    modifier = Modifier
                        .clickable { expanded = !expanded }
                        .padding(vertical = 6.dp),
                )
            }
        }
        return
    }

    Box(modifier = Modifier.fillMaxWidth()) {
        if (value.isEmpty()) {
            Text(
                text = label,
                fontSize = 14.5.sp,
                lineHeight = 20.sp,
                color = mutedInk.copy(alpha = 0.55f),
            )
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            textStyle = MaterialTheme.typography.bodyMedium.copy(
                fontSize = 14.5.sp,
                lineHeight = 20.sp,
                color = ink,
            ),
            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
            minLines = 1,
            maxLines = 12,
            modifier = Modifier
                .fillMaxWidth()
                .focusRequester(focusRequester)
                .semantics { contentDescription = label }
                .onFocusChanged { focus ->
                    if (focus.isFocused) editing = true else if (focused) editing = false
                    onFocusedChange(focus.isFocused)
                },
        )
    }
}

private fun renderNotes(raw: String, ink: Color, mutedInk: Color): AnnotatedString = buildAnnotatedString {
    PlaceNotes.previewLines(raw).forEach { line ->
        when (line) {
            // A paragraph of its own: the space a blank line takes.
            NotesPreviewLine.Blank -> withStyle(ParagraphStyle()) { append(" ") }
            is NotesPreviewLine.Heading -> withStyle(ParagraphStyle()) {
                val style = if (line.level >= 3) {
                    SpanStyle(fontSize = 13.sp, color = mutedInk)
                } else {
                    SpanStyle(fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold, color = ink)
                }
                withStyle(style) { appendInline(line.text) }
            }
            is NotesPreviewLine.Item -> withStyle(
                ParagraphStyle(
                    textIndent = TextIndent(
                        firstLine = line.depth.em,
                        restLine = (line.depth + 1).em,
                    ),
                ),
            ) {
                append("${line.marker} ")
                appendInline(line.text)
            }
            is NotesPreviewLine.Quote -> withStyle(ParagraphStyle()) {
                withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { appendInline(line.text) }
            }
            is NotesPreviewLine.Body -> withStyle(ParagraphStyle()) { appendInline(line.text) }
        }
    }
}

private val inlineMarkdown = Regex("""\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)]\(([^)]+)\)|\*(.+?)\*""")

/** Inline markdown of one line: **bold**, *italic*, `code`, [links]. */
private fun AnnotatedString.Builder.appendInline(text: String) {
    var end = 0
    inlineMarkdown.findAll(text).forEach { match ->
        append(text.substring(end, match.range.first))
        end = match.range.last + 1
        val (bold, code, link, _, italic) = match.destructured
        when {
            bold.isNotEmpty() -> withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(bold) }
            code.isNotEmpty() -> withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(code) }
            link.isNotEmpty() -> withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { append(link) }
            else -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(italic) }
        }
    }
    append(text.substring(end))
}
