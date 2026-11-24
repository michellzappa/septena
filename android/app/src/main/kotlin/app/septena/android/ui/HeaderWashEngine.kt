package app.septena.android.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Procedural Header Wash, ported from SeptenaCore/HeaderWashEngine.swift
// (ADR 0019, docs/CUSTOMIZATION_SPEC.md). The same seed gives the same terrain
// on every platform: the PRNG, the noise volume and the seeds match the Swift
// code bit for bit (HeaderWashNoiseTest). Keep the two in step until the
// generator moves into the shared core.

/** Inputs for one Header Wash frame. Sizes are in dp. */
internal data class HeaderWashParams(
    val style: String,
    val isDark: Boolean,
    val accent: Color,
    /** 15...100 */
    val intensity: Int,
    val seed: Int,
    /** Seconds of slow drift (`0` when still). */
    val phase: Double,
    /** Height in dp over which the wash fades to transparent. */
    val fadeHeight: Float,
    /** Settings thumbnail: denser frequency, no fade. */
    val mini: Boolean,
)

/** Deterministic seeds (FNV-1a), as `AppearancePreferences` derives them on Apple. */
internal object HeaderWashSeeds {
    fun fnv1a(input: String): Int {
        var hash = 0x811C9DC5.toInt()
        for (byte in input.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toInt() and 0xFF)
            hash *= 16777619
        }
        return hash
    }

    /** Daily terrain seed from the day (`YYYY-MM-DD`), the same on every device. */
    fun dailySeed(dayIso: String): Int = reduce(fnv1a("septena.wash:$dayIso"))

    private fun reduce(hash: Int): Int = max(1L, (hash.toLong() and 0xFFFFFFFFL) % 9999L).toInt()
}

/** Mulberry32, on 32-bit wrapping ints like the Swift `UInt32` version. */
internal class Mulberry32(private var state: Int) {
    fun next(): Double {
        state += 0x6D2B79F5
        var t = state
        t = (t xor (t ushr 15)) * (t or 1)
        t = t xor (t + ((t xor (t ushr 7)) * (t or 61)))
        return ((t xor (t ushr 14)).toLong() and 0xFFFFFFFFL).toDouble() / 4294967296.0
    }
}

/** Cached 3D value-noise fBm volume for one seed. */
internal class NoiseVolume(seed: Int) {
    private val perm: IntArray
    private val vals: DoubleArray

    init {
        val rng = Mulberry32(seed * 9973 + 17)
        val p = IntArray(256) { it }
        val v = DoubleArray(256)
        for (i in 0 until 256) v[i] = rng.next()
        for (i in 255 downTo 1) {
            val j = (rng.next() * (i + 1)).toInt()
            val tmp = p[i]
            p[i] = p[j]
            p[j] = tmp
        }
        perm = IntArray(512) { p[it and 255] }
        vals = v
    }

    private fun fade(t: Double): Double = t * t * t * (t * (t * 6 - 15) + 10)

    private fun lerp(a: Double, b: Double, t: Double): Double = a + (b - a) * t

    private fun valueNoise3D(x: Double, y: Double, z: Double): Double {
        val fx = floor(x)
        val fy = floor(y)
        val fz = floor(z)
        val xi = fx.toInt() and 255
        val yi = fy.toInt() and 255
        val zi = fz.toInt() and 255
        val u = fade(x - fx)
        val v = fade(y - fy)
        val w = fade(z - fz)

        val p00 = perm[perm[xi] + yi]
        val p10 = perm[perm[xi + 1] + yi]
        val p01 = perm[perm[xi] + yi + 1]
        val p11 = perm[perm[xi + 1] + yi + 1]

        val n000 = vals[perm[(p00 + zi) and 255]]
        val n100 = vals[perm[(p10 + zi) and 255]]
        val n010 = vals[perm[(p01 + zi) and 255]]
        val n110 = vals[perm[(p11 + zi) and 255]]

        if (w == 0.0) return lerp(lerp(n000, n100, u), lerp(n010, n110, u), v)

        val z1 = (zi + 1) and 255
        val n001 = vals[perm[(p00 + z1) and 255]]
        val n101 = vals[perm[(p10 + z1) and 255]]
        val n011 = vals[perm[(p01 + z1) and 255]]
        val n111 = vals[perm[(p11 + z1) and 255]]

        val nx0 = lerp(lerp(n000, n100, u), lerp(n010, n110, u), v)
        val nx1 = lerp(lerp(n001, n101, u), lerp(n011, n111, u), v)
        return lerp(nx0, nx1, w)
    }

    fun fbm(x: Double, y: Double, z: Double, octaves: Int): Double {
        var total = 0.0
        var amp = 0.5
        var freq = 1.0
        var norm = 0.0
        for (o in 0 until octaves) {
            total += valueNoise3D(x * freq, y * freq, z * (1.0 + o * 0.35)) * amp
            norm += amp
            amp *= 0.5
            freq *= 2.02
        }
        return total / norm
    }

    companion object {
        private val cache = LinkedHashMap<Int, NoiseVolume>()

        fun forSeed(seed: Int): NoiseVolume = synchronized(cache) {
            cache[seed] ?: NoiseVolume(seed).also {
                if (cache.size > 24) cache.clear()
                cache[seed] = it
            }
        }
    }
}

internal object HeaderWashEngine {
    private const val TOPOGRAPHY = "topography"
    private const val FIELD_MATRIX = "fieldMatrix"
    private const val STIPPLE_DRIFT = "stippleDrift"
    private const val RIDGES = "ridges"
    private const val WASHI_PAPER = "washiPaper"

    /**
     * Draws the wash at the top-left of the scope, in dp units. The caller
     * scales the scope by its density, so [size] is in dp too.
     */
    fun DrawScope.drawHeaderWash(size: Size, params: HeaderWashParams) {
        if (params.style == AppearanceState.TEXTURE_NONE || size.width <= 1f || size.height <= 1f) return
        val w = size.width.toDouble()
        val h = (if (params.mini) size.height else min(size.height, params.fadeHeight)).toDouble()
        if (h <= 1.0) return

        val intensity = max(10, min(100, params.intensity)) / 100.0

        // Pure geometry ink, harmonized 58% toward the accent (Jabuticaba stays ink).
        val neutral = if (params.isDark) {
            Triple(235.0 / 255.0, 240.0 / 255.0, 248.0 / 255.0)
        } else {
            Triple(30.0 / 255.0, 36.0 / 255.0, 48.0 / 255.0)
        }
        val ink = Triple(
            neutral.first * 0.42 + params.accent.red * 0.58,
            neutral.second * 0.42 + params.accent.green * 0.58,
            neutral.third * 0.42 + params.accent.blue * 0.58,
        )
        val ctx = Ink(ink)

        val vol = NoiseVolume.forSeed(params.seed)
        val zSlice = params.phase * 0.036
        val sample: (Double, Double, Int) -> Double = { x, y, octaves -> vol.fbm(x, y, zSlice, octaves) }

        clipRect(0f, 0f, w.toFloat(), h.toFloat()) {
            when (params.style) {
                TOPOGRAPHY -> drawTopography(ctx, w, h, params.isDark, intensity, params.mini, sample)
                FIELD_MATRIX -> drawFieldMatrix(ctx, w, h, params.isDark, intensity, params.mini, params.phase, vol)
                STIPPLE_DRIFT -> drawStippleDrift(ctx, w, h, params.isDark, intensity, params.seed, params.mini, sample)
                RIDGES -> drawRidges(ctx, w, h, params.isDark, intensity, params.mini, sample)
                WASHI_PAPER -> drawWashiPaper(ctx, w, h, params.isDark, intensity, params.seed, params.mini, sample)
            }
            // Vertical fade to transparent (not on the small Settings thumbnails).
            // The caller draws into its own bitmap, so DstIn masks only the wash.
            if (!params.mini) {
                drawRect(
                    brush = Brush.verticalGradient(
                        0f to Color.Black,
                        0.56f to Color.Black.copy(alpha = 0.58f),
                        1f to Color.Transparent,
                        startY = 0f,
                        endY = h.toFloat(),
                    ),
                    topLeft = Offset.Zero,
                    size = Size(w.toFloat(), h.toFloat()),
                    blendMode = BlendMode.DstIn,
                )
            }
        }
    }

    private class Ink(private val rgb: Triple<Double, Double, Double>) {
        fun color(alpha: Double): Color = Color(
            red = rgb.first.toFloat().coerceIn(0f, 1f),
            green = rgb.second.toFloat().coerceIn(0f, 1f),
            blue = rgb.third.toFloat().coerceIn(0f, 1f),
            alpha = alpha.toFloat().coerceIn(0f, 1f),
        )
    }

    // 1. Topography: marching squares over 3D fBm.
    private fun DrawScope.drawTopography(
        ink: Ink, w: Double, h: Double, isDark: Boolean, intensity: Double, mini: Boolean,
        sample: (Double, Double, Int) -> Double,
    ) {
        val step = if (mini) 5.0 else 8.0
        val cols = ceil(w / step).toInt() + 1
        val rows = ceil(h / step).toInt() + 1
        val freq = if (mini) 0.016 else 0.0055

        val grid = DoubleArray(cols * rows)
        for (r in 0 until rows) {
            val sy = r * step * freq
            for (c in 0 until cols) grid[r * cols + c] = sample(c * step * freq, sy, 4)
        }

        val levels = if (mini) 8 else 13
        for (l in 0 until levels) {
            val thresh = 0.22 + (l.toDouble() / (levels - 1)) * 0.56
            val isIndex = l % 4 == 0
            val baseAlpha = if (isDark) (if (isIndex) 0.30 else 0.14) else (if (isIndex) 0.26 else 0.12)
            val path = Path()
            fun interp(va: Double, vb: Double): Double {
                val d = vb - va
                return if (abs(d) < 1e-5) 0.5 else (thresh - va) / d
            }
            fun seg(ax: Double, ay: Double, bx: Double, by: Double) {
                path.moveTo(ax.toFloat(), ay.toFloat())
                path.lineTo(bx.toFloat(), by.toFloat())
            }
            for (r in 0 until rows - 1) {
                for (c in 0 until cols - 1) {
                    val v0 = grid[r * cols + c]
                    val v1 = grid[r * cols + c + 1]
                    val v2 = grid[(r + 1) * cols + c + 1]
                    val v3 = grid[(r + 1) * cols + c]
                    val idx = (if (v0 > thresh) 1 else 0) or (if (v1 > thresh) 2 else 0) or
                        (if (v2 > thresh) 4 else 0) or (if (v3 > thresh) 8 else 0)
                    if (idx == 0 || idx == 15) continue

                    val x = c * step
                    val y = r * step
                    val topX = x + interp(v0, v1) * step
                    val rightY = y + interp(v1, v2) * step
                    val bottomX = x + interp(v3, v2) * step
                    val leftY = y + interp(v0, v3) * step
                    val right = x + step
                    val bottom = y + step
                    when (idx) {
                        1, 14 -> seg(x, leftY, topX, y)
                        2, 13 -> seg(topX, y, right, rightY)
                        3, 12 -> seg(x, leftY, right, rightY)
                        4, 11 -> seg(right, rightY, bottomX, bottom)
                        5 -> { seg(x, leftY, bottomX, bottom); seg(topX, y, right, rightY) }
                        6, 9 -> seg(topX, y, bottomX, bottom)
                        7, 8 -> seg(x, leftY, bottomX, bottom)
                        10 -> { seg(x, leftY, topX, y); seg(right, rightY, bottomX, bottom) }
                    }
                }
            }
            drawPath(
                path = path,
                color = ink.color(baseAlpha * (0.45 + intensity * 0.95)),
                style = Stroke(width = if (isIndex) 1.25f else 0.75f),
            )
        }
    }

    // 2. Field Matrix: elevation-modulated micro-dots.
    private fun DrawScope.drawFieldMatrix(
        ink: Ink, w: Double, h: Double, isDark: Boolean, intensity: Double, mini: Boolean,
        phase: Double, vol: NoiseVolume,
    ) {
        val gap = if (mini) 8.5 else 14.0
        val freq = if (mini) 0.018 else 0.0065
        val maxR = (if (mini) 2.0 else 2.9) * (0.65 + intensity * 0.55)
        val alphaBase = if (isDark) 0.36 else 0.30
        // Dots need a faster slice than contour lines to read as alive.
        val z = phase * 0.18

        var y = gap / 2
        while (y < h) {
            var x = gap / 2
            while (x < w) {
                val v = vol.fbm(x * freq, y * freq, z, 3)
                val norm = max(0.0, min(1.0, (v - 0.26) / 0.48))
                val r = 0.45 + norm * norm * maxR
                drawCircle(
                    color = ink.color((0.04 + norm * alphaBase) * (0.4 + intensity * 0.85)),
                    radius = r.toFloat(),
                    center = Offset(x.toFloat(), y.toFloat()),
                )
                x += gap
            }
            y += gap
        }
    }

    // 3. Stipple Drift: fixed-anchor stipple dither (no flicker).
    private fun DrawScope.drawStippleDrift(
        ink: Ink, w: Double, h: Double, isDark: Boolean, intensity: Double, seed: Int, mini: Boolean,
        sample: (Double, Double, Int) -> Double,
    ) {
        val rng = Mulberry32(seed + 303)
        val count = ((w * h) / (if (mini) 12.0 else 18.0)).toInt()
        val freq = if (mini) 0.014 else 0.005
        val base = (if (isDark) 0.27 else 0.24) * (0.35 + intensity * 0.85)

        repeat(count) {
            val x = rng.next() * w
            val y = rng.next() * h
            val gate = rng.next()
            val isBig = rng.next() > 0.82
            val wave = sin(sample(x * freq, y * freq, 3) * PI * 6.5) * 0.5 + 0.5
            if (gate < wave * 0.65) {
                val s = if (isBig) 1.5f else 1.0f
                drawRect(
                    color = ink.color(base * (0.4 + wave * 0.6)),
                    topLeft = Offset(x.toFloat(), y.toFloat()),
                    size = Size(s, s),
                )
            }
        }
    }

    // 4. Ridge Lines: displaced elevation profiles.
    private fun DrawScope.drawRidges(
        ink: Ink, w: Double, h: Double, isDark: Boolean, intensity: Double, mini: Boolean,
        sample: (Double, Double, Int) -> Double,
    ) {
        val spacing = if (mini) 8.5 else 13.5
        val amp = (if (mini) 15.0 else 32.0) * (0.55 + intensity * 0.65)
        val freqX = if (mini) 0.015 else 0.0055
        val freqY = 0.008
        val stepX = if (mini) 4.0 else 6.0

        var y = -amp
        while (y < h + amp) {
            val rowNorm = max(0.0, min(1.0, y / max(1.0, h)))
            val alpha = (if (isDark) 0.24 else 0.21) * (0.4 + intensity * 0.85) * (0.55 + 0.45 * sin(rowNorm * PI))
            val path = Path()
            var x = 0.0
            var first = true
            while (x <= w + stepX) {
                val py = y + (sample(x * freqX + 1.3, y * freqY + 2.7, 3) - 0.5) * amp * 2.1
                if (first) {
                    path.moveTo(x.toFloat(), py.toFloat())
                    first = false
                } else {
                    path.lineTo(x.toFloat(), py.toFloat())
                }
                x += stepX
            }
            drawPath(path, ink.color(alpha), style = Stroke(width = 0.95f))
            y += spacing
        }
    }

    // 5. Washi Paper: laid sugeta screen lines and sinuous kozo fibers.
    private fun DrawScope.drawWashiPaper(
        ink: Ink, w: Double, h: Double, isDark: Boolean, intensity: Double, seed: Int, mini: Boolean,
        sample: (Double, Double, Int) -> Double,
    ) {
        val rng = Mulberry32(seed + 777)
        val freq = if (mini) 0.016 else 0.006
        val strength = 0.45 + intensity * 0.9

        // 1. Laid-paper screen lines.
        val laid = Path()
        val laidStep = if (mini) 5.0 else 6.0
        var y = laidStep / 2
        while (y < h) {
            laid.moveTo(0f, y.toFloat())
            laid.lineTo(w.toFloat(), y.toFloat())
            y += laidStep
        }
        val chainStep = if (mini) 28.0 else 48.0
        var x = chainStep
        while (x < w) {
            laid.moveTo(x.toFloat(), 0f)
            laid.lineTo(x.toFloat(), h.toFloat())
            x += chainStep
        }
        drawPath(laid, ink.color((if (isDark) 0.075 else 0.065) * strength), style = Stroke(width = 0.6f))

        // 2. Long sinuous mulberry fibers.
        val longCount = max(20, ((w * h) / (if (mini) 380.0 else 1250.0)).toInt())
        repeat(longCount) {
            val fx = rng.next() * w
            val fy = rng.next() * h
            val angle = (rng.next() - 0.5) * PI * 1.4
            val len = (if (mini) 14.0 else 26.0) + rng.next() * (if (mini) 22.0 else 46.0)
            val bend = (rng.next() - 0.5) * len * 0.65
            val mx = fx + cos(angle) * len * 0.5 - sin(angle) * bend
            val my = fy + sin(angle) * len * 0.5 + cos(angle) * bend
            val ex = fx + cos(angle) * len
            val ey = fy + sin(angle) * len
            val alphaRand = rng.next()
            val thick = rng.next() > 0.72
            val wave = 0.55 + sample(fx * freq, fy * freq, 2) * 0.75
            val fiber = Path().apply {
                moveTo(fx.toFloat(), fy.toFloat())
                quadraticTo(mx.toFloat(), my.toFloat(), ex.toFloat(), ey.toFloat())
            }
            drawPath(
                fiber,
                ink.color((if (isDark) 0.28 else 0.24) * strength * wave * (0.55 + alphaRand * 0.55)),
                style = Stroke(width = if (thick) 1.35f else 0.85f, cap = StrokeCap.Round),
            )
        }

        // 3. Short pulp micro-fibers.
        val shortCount = ((w * h) / (if (mini) 95.0 else 165.0)).toInt()
        repeat(shortCount) {
            val fx = rng.next() * w
            val fy = rng.next() * h
            val angle = rng.next() * PI * 2
            val len = 3.0 + rng.next() * 8.0
            val alphaRand = rng.next()
            val wave = 0.5 + sample(fx * freq, fy * freq, 2) * 0.8
            drawLine(
                color = ink.color((if (isDark) 0.16 else 0.14) * strength * wave * (0.45 + alphaRand * 0.65)),
                start = Offset(fx.toFloat(), fy.toFloat()),
                end = Offset((fx + cos(angle) * len).toFloat(), (fy + sin(angle) * len).toFloat()),
                strokeWidth = 0.75f,
                cap = StrokeCap.Round,
            )
        }
    }
}
