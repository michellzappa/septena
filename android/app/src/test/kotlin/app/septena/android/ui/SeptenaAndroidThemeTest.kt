package app.septena.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Launch guard for the theme (F3, #344). #308 built registry colors as the
 * packed Color(ULong) value, and MaterialTheme crashed on every launch when
 * it called copy(alpha) on them (#341). This builds the same colors for every
 * accent and makes the same call.
 */
class SeptenaAndroidThemeTest {
    @Test
    fun registryColorsAreSrgbAndCopyable() {
        for (fruit in FruitAccents.all) {
            for (dark in listOf(false, true)) {
                val colors = registryThemeColors(dark, fruit.id)
                for (color in listOf(colors.accent, colors.onAccent, colors.todayGlyph, colors.magicPlus, colors.magicPlusInk)) {
                    assertEquals(1f, color.alpha)
                    assertEquals(0.4f, color.copy(alpha = 0.4f).alpha, 0.01f)
                    assertEquals("sRGB IEC61966-2.1", color.colorSpace.name)
                }
            }
        }
    }

    /** tokens.json `multicolorGlyphs`: Today stays gold only under the multicolor fruit. */
    @Test
    fun todayGlyphIsGoldOnlyUnderColorful() {
        for (fruit in FruitAccents.all) {
            val colors = registryThemeColors(darkTheme = false, accentId = fruit.id)
            if (fruit.multicolor) {
                assertNotEquals(colors.accent, colors.todayGlyph)
                val persimmon = FruitAccents.resolve("persimmon")
                assertEquals(persimmon.color(dark = false), colors.magicPlus)
            } else {
                assertEquals(colors.accent, colors.todayGlyph)
                assertEquals(colors.accent, colors.magicPlus)
            }
        }
    }

    @Test
    fun textScaleFollowsTokens() {
        assertEquals(1f, textScaleFactor(0), 0.001f)
        assertEquals(0.85f, textScaleFactor(-2), 0.001f)
        assertEquals(1.2f, textScaleFactor(2), 0.001f)
    }
}

/**
 * The Header Wash must draw the same terrain as iPhone on the same day. These
 * values come from running the Swift code (AppearancePreferences, HeaderWashEngine).
 */
class HeaderWashNoiseTest {
    @Test
    fun dailySeedMatchesApple() {
        assertEquals(4866, HeaderWashSeeds.dailySeed("2026-11-24"))
        assertEquals(1969, HeaderWashSeeds.dailySeed("2025-01-01"))
    }

    @Test
    fun mulberry32MatchesApple() {
        val rng = Mulberry32(1234)
        assertEquals(0.07329497812315822, rng.next(), 1e-15)
        assertEquals(0.7034119898453355, rng.next(), 1e-15)
        assertEquals(0.9028560190927237, rng.next(), 1e-15)
    }

    @Test
    fun noiseVolumeMatchesApple() {
        val volume = NoiseVolume(4866)
        assertEquals(0.5447052758302734, volume.fbm(1.37, 2.81, 0.0, 4), 1e-12)
        assertEquals(0.5050099439151439, volume.fbm(300.2, 0.45, 0.72, 3), 1e-12)
    }
}
