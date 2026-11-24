package app.septena.android.ui

import android.os.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.isSystemInDarkTheme
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue

/** Material 3 shell colors sourced from Septena's shared semantic token registry. */
@Composable
fun SeptenaAndroidTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val darkTheme = isSystemInDarkTheme()
    val colors = remember(darkTheme) {
        val tokens = RegistryCatalog.document("tokens")
        val accents = (tokens.fields["fruitAccents"] as? JsonValue.ArrayValue)?.values.orEmpty()
        val colorful = accents
            .mapNotNull { it as? JsonValue.ObjectValue }
            .firstOrNull { it.fields["id"].stringValue() == "colorful" }
            ?: error("Missing Colorful accent in registry/tokens.json")
        val accent = registryColor(colorful.fields[if (darkTheme) "dark" else "light"])
        val onAccent = registryColor(colorful.fields[if (darkTheme) "checkDark" else "checkLight"])
        val tokenColors = tokens.fields["colors"] as? JsonValue.ObjectValue
            ?: error("Missing semantic colors in registry/tokens.json")
        val today = registryColor(tokenColors.fields["todayAccent"])
        val systemColors = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else if (darkTheme) {
            darkColorScheme()
        } else {
            lightColorScheme()
        }
        systemColors.copy(
            primary = accent,
            onPrimary = onAccent,
            secondary = today,
            onSecondary = Color.Black,
            tertiary = accent,
            onTertiary = onAccent,
        )
    }

    MaterialTheme(colorScheme = colors, content = content)
}

private fun registryColor(value: JsonValue?): Color {
    val hex = requireNotNull(value.stringValue()) { "Missing color token" }.removePrefix("#")
    val rgb = requireNotNull(hex.toLongOrNull(16)) { "Invalid color token '#$hex'" }
    // Color(Long) reads 0xAARRGGBB in sRGB. Color(ULong) is the packed internal
    // form, whose low bits name the color space: 0xFF…RRGGBB there read as
    // color space 63 and crashed at launch (ArrayIndexOutOfBounds, index 63).
    return Color(0xFF000000L or rgb)
}
