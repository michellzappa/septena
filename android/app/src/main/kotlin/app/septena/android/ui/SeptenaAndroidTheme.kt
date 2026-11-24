package app.septena.android.ui

import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.LocalActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryIconIds
import app.septena.core.stringValue

/** The appearance store, for the Settings picker. Null outside [SeptenaAndroidTheme]. */
val LocalAppearanceStore = staticCompositionLocalOf<AppearanceStore?> { null }

/** The applied appearance, for surfaces that draw with it (header texture, picker). */
val LocalAppearance = staticCompositionLocalOf { AppearanceState.defaults() }

/** True when the applied appearance is dark (after the user's mode choice). */
val LocalSeptenaDarkTheme = staticCompositionLocalOf { false }

/**
 * Material 3 shell theme driven by the user's appearance choices
 * (ADR 0019): the fruit accent from registry/tokens.json, light or dark mode,
 * and the text size step.
 */
@Composable
fun SeptenaAndroidTheme(store: AppearanceStore, content: @Composable () -> Unit) {
    val appearance by store.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val darkTheme = when (appearance.mode) {
        AppearanceState.MODE_LIGHT -> false
        AppearanceState.MODE_DARK -> true
        else -> isSystemInDarkTheme()
    }
    val colors = remember(darkTheme, appearance.accentId) {
        val systemColors = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else if (darkTheme) {
            darkColorScheme()
        } else {
            lightColorScheme()
        }
        systemColors.withAccent(registryThemeColors(darkTheme, appearance.accentId))
    }

    // The status and navigation bar icons follow the chosen mode, not only the system's.
    val activity = LocalActivity.current as? ComponentActivity
    LaunchedEffect(activity, darkTheme) {
        activity?.enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(
                android.graphics.Color.TRANSPARENT,
                android.graphics.Color.TRANSPARENT,
            ) { darkTheme },
            navigationBarStyle = SystemBarStyle.auto(LIGHT_SCRIM, DARK_SCRIM) { darkTheme },
        )
    }

    // The step scales on top of the system font size, as iPhone offsets
    // Dynamic Type: a large system size stays large and is only nudged.
    val density = LocalDensity.current
    val scaledDensity = Density(density.density, density.fontScale * textScaleFactor(appearance.textSizeStep))

    CompositionLocalProvider(
        LocalDensity provides scaledDensity,
        LocalAppearanceStore provides store,
        LocalAppearance provides appearance,
        LocalSeptenaDarkTheme provides darkTheme,
    ) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}

/** Resolved theme colors for one fruit accent in one mode. */
internal data class RegistryThemeColors(
    val accent: Color,
    val onAccent: Color,
    /** Color of the Today glyph: gold under Colorful, the accent under every other fruit. */
    val todayGlyph: Color,
    /** Accent wash behind a selected item (tokens.json `selection`). */
    val selectionAlpha: Float,
)

/** One accent from registry/tokens.json `fruitAccents`. */
internal data class FruitAccent(
    val id: String,
    val name: String,
    val light: Color,
    val dark: Color,
    val checkLight: Color,
    val checkDark: Color,
    val multicolor: Boolean,
) {
    fun color(dark: Boolean): Color = if (dark) this.dark else light
    fun check(dark: Boolean): Color = if (dark) checkDark else checkLight
}

internal object FruitAccents {
    val all: List<FruitAccent> by lazy {
        val tokens = RegistryCatalog.document("tokens")
        (tokens.fields["fruitAccents"] as? JsonValue.ArrayValue)?.values.orEmpty()
            .mapNotNull { it as? JsonValue.ObjectValue }
            .map { fruit ->
                FruitAccent(
                    id = requireNotNull(fruit.fields["id"].stringValue()) { "Accent without id" },
                    name = fruit.fields["name"].stringValue().orEmpty(),
                    light = registryColor(fruit.fields["light"]),
                    dark = registryColor(fruit.fields["dark"]),
                    checkLight = registryColor(fruit.fields["checkLight"]),
                    checkDark = registryColor(fruit.fields["checkDark"]),
                    multicolor = fruit.fields["multicolor"].booleanValue() ?: false,
                )
            }
            .also { require(it.isNotEmpty()) { "Missing fruitAccents in registry/tokens.json" } }
    }

    /** The chosen accent, or the first one (Colorful) for an unknown id. */
    fun resolve(id: String): FruitAccent = all.firstOrNull { it.id == id } ?: all.first()
}

/** Accent, on-accent, Today and selection colors from registry/tokens.json. Unit-tested (F3, #344). */
internal fun registryThemeColors(darkTheme: Boolean, accentId: String): RegistryThemeColors {
    val tokens = RegistryCatalog.document("tokens")
    val fruit = FruitAccents.resolve(accentId)
    val accent = fruit.color(darkTheme)
    val tokenColors = tokens.fields["colors"] as? JsonValue.ObjectValue
        ?: error("Missing semantic colors in registry/tokens.json")
    // tokens.json `multicolorGlyphs`: under the multicolor fruit a glyph keeps
    // its semantic color (the Today sun in gold); every other fruit tints it.
    val glyphs = (tokens.fields["multicolorGlyphs"] as? JsonValue.ObjectValue)
        ?.fields?.get("glyphs") as? JsonValue.ObjectValue
    val todayKey = glyphs?.fields?.get(RegistryIconIds.LIST_TODAY).stringValue()
    val todayGlyph = if (fruit.multicolor && todayKey != null) registryColor(tokenColors.fields[todayKey]) else accent
    val selection = tokens.fields["selection"] as? JsonValue.ObjectValue
    val alphaKey = if (darkTheme) "emphasizedAlphaDark" else "emphasizedAlphaLight"
    val alpha = (selection?.fields?.get(alphaKey) as? JsonValue.DecimalValue)?.value?.toFloat() ?: 0.22f
    return RegistryThemeColors(accent, fruit.check(darkTheme), todayGlyph, alpha)
}

/** Text size factor for a step, from tokens.json `textScale`. */
internal fun textScaleFactor(step: Int): Float {
    val scale = RegistryCatalog.document("tokens").fields["textScale"] as? JsonValue.ObjectValue
    val steps = (scale?.fields?.get("steps") as? JsonValue.ArrayValue)?.values.orEmpty()
    val match = steps.mapNotNull { it as? JsonValue.ObjectValue }
        .firstOrNull { (it.fields["step"] as? JsonValue.IntegerValue)?.value?.toInt() == step }
    return when (val factor = match?.fields?.get("factor")) {
        is JsonValue.DecimalValue -> factor.value.toFloat()
        is JsonValue.IntegerValue -> factor.value.toFloat()
        else -> 1f
    }
}

private fun ColorScheme.withAccent(theme: RegistryThemeColors): ColorScheme {
    // Selected and emphasized containers are an accent wash with normal ink
    // (docs/DesignSpec.md §4.5), never a solid bar with white text.
    val wash = theme.accent.copy(alpha = theme.selectionAlpha).compositeOver(surface)
    return copy(
        primary = theme.accent,
        onPrimary = theme.onAccent,
        primaryContainer = wash,
        onPrimaryContainer = onSurface,
        secondary = theme.todayGlyph,
        // Black ink on the Today gold; the accent pairs with its own check ink.
        onSecondary = if (theme.todayGlyph == theme.accent) theme.onAccent else Color.Black,
        secondaryContainer = wash,
        onSecondaryContainer = onSurface,
        tertiary = theme.accent,
        onTertiary = theme.onAccent,
        tertiaryContainer = wash,
        onTertiaryContainer = onSurface,
    )
}

internal fun registryColor(value: JsonValue?): Color {
    val hex = requireNotNull(value.stringValue()) { "Missing color token" }.removePrefix("#")
    val rgb = requireNotNull(hex.toLongOrNull(16)) { "Invalid color token '#$hex'" }
    // Color(Long) reads 0xAARRGGBB in sRGB. Color(ULong) is the packed internal
    // form, whose low bits name the color space: 0xFF…RRGGBB there read as
    // color space 63 and crashed at launch (ArrayIndexOutOfBounds, index 63).
    return Color(0xFF000000L or rgb)
}

// The scrims androidx.activity uses by default for a three-button navigation
// bar, as ARGB ints (android.graphics.Color is not available in unit tests).
private val LIGHT_SCRIM: Int = 0xE6FFFFFF.toInt()
private val DARK_SCRIM: Int = 0x801B1B1B.toInt()
