package app.septena.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import kotlin.math.roundToInt

/** The settings.json custom surface that draws the appearance picker. */
internal const val APPEARANCE_PICKER_SURFACE = "accent_color"

/**
 * Settings ▸ Appearance, as iPhone's `AppearancePickerView` lays it out: mode,
 * the accent tiles, the header texture tiles, and Slow drift while a texture
 * is on. Android keeps the Material segmented button and switch.
 * `syncTheme` and the texture intensity have no control here, as on iPhone;
 * both keep their stored values.
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun AppearancePicker(languageTag: String) {
    val store = LocalAppearanceStore.current ?: return
    val appearance = LocalAppearance.current
    val dark = LocalSeptenaDarkTheme.current
    val copy = remember(languageTag) { appearancePickerCopy(languageTag) }
    val textures = remember(languageTag) { registryTextures(languageTag) }
    val seed = remember { HeaderWashSeeds.dailySeed(store.dayIso()) }
    val columns = if (LocalConfiguration.current.screenWidthDp >= 600) 4 else 2
    val accent = FruitAccents.resolve(appearance.accentId).color(dark)

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // 1. Mode (device only).
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(copy.mode, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            SingleChoiceSegmentedButtonRow(modifier = Modifier.widthIn(max = 260.dp)) {
                copy.modeOptions.forEachIndexed { index, (value, title) ->
                    SegmentedButton(
                        selected = appearance.mode == value,
                        onClick = { store.setMode(value) },
                        shape = SegmentedButtonDefaults.itemShape(index, copy.modeOptions.size),
                    ) {
                        Text(title, maxLines = 1)
                    }
                }
            }
        }

        HorizontalDivider()

        // 2. Accent.
        Text(copy.accent, style = MaterialTheme.typography.titleSmall)
        TileGrid(items = FruitAccents.all, columns = columns) { fruit, modifier ->
            AccentTile(
                fruit = fruit,
                name = RegistryCatalog.localizedString(fruit.name, languageTag) ?: fruit.name,
                dark = dark,
                selected = appearance.accentId == fruit.id,
                onClick = { store.setAccent(fruit.id) },
                modifier = modifier,
            )
        }

        HorizontalDivider()

        // 3. Header texture.
        Text(copy.texture, style = MaterialTheme.typography.titleSmall)
        TileGrid(items = textures, columns = columns) { texture, modifier ->
            TextureTile(
                id = texture.first,
                name = texture.second,
                dark = dark,
                accent = accent,
                intensity = appearance.textureIntensity,
                seed = seed,
                selected = appearance.texture == texture.first,
                onClick = { store.setTexture(texture.first) },
                modifier = modifier,
            )
        }

        // 4. Slow drift, only while a texture is on.
        if (appearance.hasActiveTexture) {
            val slowDrift = appearance.textureMotion == AppearanceState.MOTION_SLOW_DRIFT
            fun toggle(on: Boolean) = store.setTextureMotion(
                if (on) AppearanceState.MOTION_SLOW_DRIFT else AppearanceState.MOTION_STILL,
            )
            Row(
                modifier = Modifier.fillMaxWidth().clickable { toggle(!slowDrift) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(copy.motion, style = MaterialTheme.typography.bodyLarge)
                    copy.motionDetail?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Switch(checked = slowDrift, onCheckedChange = ::toggle)
            }
        }
    }
}

/** Text Size row: a five-step slider labeled with tokens.json `textScale`, as on iPhone. */
@Composable
internal fun TextSizeSettingRow(label: String, languageTag: String) {
    val store = LocalAppearanceStore.current ?: return
    val step = LocalAppearance.current.textSizeStep
    var draft by remember(step) { mutableFloatStateOf(step.toFloat()) }
    val labels = remember(languageTag) { textScaleLabels(languageTag) }
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = {
            Text(labels[draft.roundToInt()].orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
        },
    )
    Slider(
        value = draft,
        onValueChange = { draft = it },
        // Applying on release keeps the slider still while the whole UI rescales.
        onValueChangeFinished = { store.setTextSizeStep(draft.roundToInt()) },
        valueRange = AppearanceState.TEXT_SIZE_MIN.toFloat()..AppearanceState.TEXT_SIZE_MAX.toFloat(),
        steps = AppearanceState.TEXT_SIZE_MAX - AppearanceState.TEXT_SIZE_MIN - 1,
        modifier = Modifier.semantics { contentDescription = label },
    )
}

@Composable
private fun <T> TileGrid(items: List<T>, columns: Int, tile: @Composable (T, Modifier) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        items.chunked(columns).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { item -> tile(item, Modifier.weight(1f)) }
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

@Composable
private fun AccentTile(
    fruit: FruitAccent,
    name: String,
    dark: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
) {
    val swatch = fruit.color(dark)
    val card = MaterialTheme.colorScheme.surfaceContainerLowest
    val shape = RoundedCornerShape(10.dp)
    Column(
        modifier = modifier
            .clip(shape)
            .background(card)
            .border(
                width = if (selected) 2.dp else 0.75.dp,
                color = if (selected) swatch else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f),
                shape = shape,
            )
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SwatchBadge(fruit = fruit, swatch = swatch, card = card)
            Text(
                name,
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // Mini row preview: done check, title bar, and the gold Today dot under Colorful.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(6.dp))
                .background(swatch.copy(alpha = if (dark) 0.24f else 0.14f))
                .padding(horizontal = 6.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(
                modifier = Modifier.size(11.dp).clip(RoundedCornerShape(3.dp)).background(swatch),
                contentAlignment = Alignment.Center,
            ) {
                CheckGlyph(color = fruit.check(dark), modifier = Modifier.size(7.dp))
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.28f)),
            )
            if (fruit.multicolor) {
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(registryThemeColors(dark, fruit.id).todayGlyph),
                )
            }
        }
    }
}

@Composable
private fun SwatchBadge(fruit: FruitAccent, swatch: Color, card: Color) {
    val ring = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)
    val wheel = remember(fruit.id) { if (fruit.multicolor) multicolorWheel() else emptyList() }
    Canvas(modifier = Modifier.size(18.dp)) {
        if (fruit.multicolor) {
            drawCircle(brush = Brush.sweepGradient(wheel))
            drawCircle(color = card, radius = 3.5.dp.toPx())
        } else {
            drawCircle(color = swatch)
            drawCircle(color = ring, style = Stroke(width = 0.5.dp.toPx()))
        }
    }
}

@Composable
private fun CheckGlyph(color: Color, modifier: Modifier) {
    Canvas(modifier = modifier) {
        val path = Path().apply {
            moveTo(size.width * 0.12f, size.height * 0.55f)
            lineTo(size.width * 0.40f, size.height * 0.82f)
            lineTo(size.width * 0.88f, size.height * 0.20f)
        }
        drawPath(path, color, style = Stroke(width = 1.4.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
private fun TextureTile(
    id: String,
    name: String,
    dark: Boolean,
    accent: Color,
    intensity: Int,
    seed: Int,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
) {
    val card = MaterialTheme.colorScheme.surfaceContainerLowest
    val shape = RoundedCornerShape(10.dp)
    val thumbShape = RoundedCornerShape(7.dp)
    val glassShape = RoundedCornerShape(4.dp)
    val glassAlpha = when {
        id == AppearanceState.TEXTURE_NONE -> 1f
        dark -> 0.62f
        else -> 0.72f
    }
    Column(
        modifier = modifier
            .clip(shape)
            .background(card)
            .border(
                width = if (selected) 2.dp else 0.75.dp,
                color = if (selected) accent else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f),
                shape = shape,
            )
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(7.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(46.dp)
                .clip(thumbShape)
                .background(MaterialTheme.colorScheme.surfaceContainer)
                .border(0.5.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f), thumbShape),
        ) {
            HeaderWashPreview(
                style = id,
                dark = dark,
                accent = accent,
                intensity = intensity,
                seed = seed,
                modifier = Modifier.fillMaxSize(),
            )
            // A glass card hint at the bottom of the thumbnail.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 6.dp, end = 6.dp, bottom = 5.dp)
                    .fillMaxWidth()
                    .height(12.dp)
                    .clip(glassShape)
                    .background(card.copy(alpha = glassAlpha))
                    .border(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), glassShape),
            )
        }
        Text(
            name,
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The Colorful badge: the semantic gold and four fruits around a wheel, as on iPhone. */
private fun multicolorWheel(): List<Color> {
    val gold = registryThemeColors(darkTheme = false, accentId = FruitAccents.all.first { it.multicolor }.id).todayGlyph
    val fruits = listOf(COLORFUL, TAMARILLO, CARAMBOLA, ACAI).map { FruitAccents.resolve(it).light }
    return listOf(gold) + fruits + gold
}

private const val COLORFUL = "colorful"
private const val TAMARILLO = "tamarillo"
private const val CARAMBOLA = "carambola"
private const val ACAI = "acai"

private data class AppearancePickerCopy(
    val mode: String,
    val accent: String,
    val texture: String,
    val motion: String,
    val motionDetail: String?,
    val modeOptions: List<Pair<String, String>>,
)

/** The picker's words: the `accent_color` item and its `parts` in settings.json. */
private fun appearancePickerCopy(languageTag: String): AppearancePickerCopy {
    fun String.localized(): String = RegistryCatalog.localizedString(this, languageTag) ?: this
    val settings = RegistryCatalog.document("settings")
    val item = settings.arrayAt("pages")
        .flatMap { it.arrayAt("sections") }
        .flatMap { it.arrayAt("items") }
        .firstOrNull { it.fields["surface"].stringValue() == APPEARANCE_PICKER_SURFACE }
        ?: error("Missing the $APPEARANCE_PICKER_SURFACE surface in registry/settings.json")
    val parts = item.arrayAt("parts").associateBy { it.fields["id"].stringValue() }
    fun label(id: String): String = parts[id]?.fields?.get("label").stringValue().orEmpty().localized()
    val motion = parts[PART_MOTION]
    val motionDetail = motion?.arrayAt("platformDetails")
        ?.firstOrNull { detail -> detail.arrayAt("platforms").any { it.stringValue() == RegistryPlatformIds.ANDROID } }
        ?.fields?.get("detail").stringValue()
        ?: motion?.fields?.get("detail").stringValue()
    val modeOptions = (RegistryCatalog.setting(RegistrySettingKeys.APPEARANCE_MODE)?.fields?.get("options") as? JsonValue.ArrayValue)
        ?.values.orEmpty()
        .mapNotNull { it as? JsonValue.ObjectValue }
        .mapNotNull { option ->
            val value = option.fields["value"].stringValue() ?: return@mapNotNull null
            val title = option.fields["title"].stringValue() ?: return@mapNotNull null
            value to title.localized()
        }
    return AppearancePickerCopy(
        mode = label(PART_MODE),
        accent = item.fields["label"].stringValue().orEmpty().localized(),
        texture = label(PART_TEXTURE),
        motion = label(PART_MOTION),
        motionDetail = motionDetail?.localized(),
        modeOptions = modeOptions,
    )
}

/** Texture ids and names from tokens.json `textures`, Pure Canvas first. */
private fun registryTextures(languageTag: String): List<Pair<String, String>> =
    RegistryCatalog.document("tokens").arrayAt("textures").mapNotNull { texture ->
        val id = texture.fields["id"].stringValue() ?: return@mapNotNull null
        val name = texture.fields["name"].stringValue() ?: return@mapNotNull null
        id to (RegistryCatalog.localizedString(name, languageTag) ?: name)
    }

/** Step → label from tokens.json `textScale`. */
private fun textScaleLabels(languageTag: String): Map<Int, String> {
    val scale = RegistryCatalog.document("tokens").fields["textScale"] as? JsonValue.ObjectValue ?: return emptyMap()
    return scale.arrayAt("steps").mapNotNull { step ->
        val value = (step.fields["step"] as? JsonValue.IntegerValue)?.value?.toInt() ?: return@mapNotNull null
        val label = step.fields["label"].stringValue() ?: return@mapNotNull null
        value to (RegistryCatalog.localizedString(label, languageTag) ?: label)
    }.toMap()
}

private fun JsonValue.ObjectValue.arrayAt(key: String): List<JsonValue.ObjectValue> =
    (fields[key] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { it as? JsonValue.ObjectValue }

private const val PART_MODE = "mode"
private const val PART_TEXTURE = "texture"
private const val PART_MOTION = "motion"
