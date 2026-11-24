package app.septena.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Launch guard for the theme (F3, #344). #308 built registry colors as the
 * packed Color(ULong) value, and MaterialTheme crashed on every launch when
 * it called copy(alpha) on them (#341). This builds the same colors and makes
 * the same call.
 */
class SeptenaAndroidThemeTest {
    @Test
    fun registryColorsAreSrgbAndCopyable() {
        for (dark in listOf(false, true)) {
            val (accent, onAccent, today) = registryThemeColors(dark)
            for (color in listOf(accent, onAccent, today)) {
                assertEquals(1f, color.alpha)
                assertEquals(0.4f, color.copy(alpha = 0.4f).alpha, 0.01f)
                assertEquals("sRGB IEC61966-2.1", color.colorSpace.name)
            }
        }
    }
}
