package app.septena.ui

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.septena.ui.generated.registryIconVector

/**
 * A glyph from registry/icons.json (`material`). Draws nothing for an ID the
 * registry does not know, so a missing icon never shows a wrong one.
 * [contentDescription] is null for a glyph next to a text label.
 */
@Composable
fun RegistryIcon(
    id: String?,
    contentDescription: String?,
    modifier: Modifier = Modifier,
    tint: Color = LocalContentColor.current,
    on: Boolean = false,
    size: Dp = 24.dp,
) {
    val vector = id?.let { registryIconVector(it, on) } ?: return
    Icon(vector, contentDescription = contentDescription, modifier = modifier.size(size), tint = tint)
}
