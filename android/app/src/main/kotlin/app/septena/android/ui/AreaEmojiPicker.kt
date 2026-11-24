package app.septena.android.ui

import android.icu.text.BreakIterator
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.IconButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.stringValue
import java.util.Locale

@Composable
fun AreaEmojiButton(
    emoji: String?,
    accessibilityLabel: String,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier.semantics { contentDescription = accessibilityLabel },
    ) {
        Text(
            text = emoji ?: "☺",
            style = if (emoji == null) MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineSmall,
            color = if (emoji == null) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun AreaEmojiPickerSheet(
    initialEmoji: String?,
    languageTag: String,
    onDismissRequest: () -> Unit,
    onSelect: (String) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val changeEmojiTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.AREA_CHANGE_EMOJI,
        languageTag = languageTag,
    ).orEmpty()
    val clearTitle = RegistryCatalog.surface(RegistryPromptIds.CLEAR_LOGGED)
        ?.fields?.get("confirmTitle")?.stringValue()
        ?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }
        .orEmpty()
    var draft by rememberSaveable { mutableStateOf(initialEmoji.orEmpty()) }
    var lastSaved by remember { mutableStateOf(initialEmoji.orEmpty()) }

    fun commit(value: String) {
        draft = value
        if (value != lastSaved) {
            lastSaved = value
            onSelect(value)
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 560.dp)
                .padding(horizontal = 16.dp)
                .padding(bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(changeEmojiTitle, style = MaterialTheme.typography.titleMedium)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { commit(it.lastGrapheme()) },
                    modifier = Modifier.weight(1f),
                    label = { Text(changeEmojiTitle) },
                    singleLine = true,
                    textStyle = MaterialTheme.typography.headlineSmall.copy(textAlign = TextAlign.Center),
                )
                TextButton(
                    enabled = draft.isNotEmpty(),
                    onClick = {
                        commit("")
                        onDismissRequest()
                    },
                ) {
                    Text(clearTitle)
                }
            }
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 44.dp),
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(bottom = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                items(CURATED_AREA_EMOJI.distinct(), key = { it }) { emoji ->
                    TextButton(
                        onClick = {
                            commit(emoji)
                            onDismissRequest()
                        },
                        modifier = Modifier.aspectRatio(1f),
                        contentPadding = PaddingValues(0.dp),
                    ) {
                        Text(
                            text = emoji,
                            style = MaterialTheme.typography.headlineSmall,
                            modifier = Modifier.semantics { contentDescription = emoji },
                        )
                    }
                }
            }
        }
    }
}

private fun String.lastGrapheme(): String {
    if (isEmpty()) return ""
    val iterator = BreakIterator.getCharacterInstance(Locale.getDefault())
    iterator.setText(this)
    val end = iterator.last()
    val start = iterator.preceding(end)
    return if (start == BreakIterator.DONE) this else substring(start, end)
}

/** Mirrors the curated glyph choices in Septena's shared EmojiPickerContent. */
private val CURATED_AREA_EMOJI = listOf(
    "💧", "🏃", "🚶", "🧘", "🤸", "🛌", "🚿", "🪥", "📖", "✍️", "📝", "🗣️", "📵", "☕", "🎧", "🙏",
    "💊", "💉", "🩹", "🩺", "🌡️", "💪", "🧠", "🫀", "🫁", "🦴", "🦵", "🦷", "👁️", "👂", "👃", "🩸", "🦠", "🧬", "🤕", "🤢", "🤧", "😷", "🪫", "🩻",
    "🍎", "🍌", "🍓", "🥑", "🥦", "🥕", "🥗", "🍞", "🍚", "🍗", "🥩", "🥚", "🐟", "🥛", "🧀", "🥜", "🍳", "🍵", "🧃", "🍫", "🍯", "🧂", "🌾",
    "🍽️", "🗑️", "🧺", "🧹", "🧽", "🧼", "🧻", "🛁", "🛏️", "🪣", "🧊", "🪟", "🪴", "🛋️", "🚪", "🔧", "🪛", "⚙️", "🧯", "🔌",
    "🏋️", "🚴", "🏊", "🧗", "⛹️", "🤾", "🥊", "🎯", "⚽", "🏀", "🎾", "🏆", "🥾", "🏅",
    "☀️", "🌙", "⭐", "🔥", "💨", "🌀", "🌫️", "🌧️", "❄️", "🌊", "🌱", "🌿", "🌸", "🍂", "🌲", "⛰️", "🪨", "🎈",
    "💻", "📚", "📅", "⏰", "💡", "🎯", "📌", "🗂️", "🧮", "🔬", "🎓", "📞", "✉️", "🔔", "🏷️", "💼",
    "❤️", "🧡", "💛", "💚", "💙", "💜", "⭐", "✅", "⚠️", "♻️", "➕", "🔁", "❓", "🔆", "🌟", "🏁",
)
