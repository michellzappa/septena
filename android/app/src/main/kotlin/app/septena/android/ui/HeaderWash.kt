package app.septena.android.ui

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The procedural Header Wash behind the top of a task list (ADR 0019), as
 * `HeaderWashView` draws it on iPhone: anchored to the top edge, fading to
 * transparent over [fadeHeight]. It draws nothing while the texture is Pure
 * Canvas. A still wash renders once into a cached bitmap; Slow drift renders
 * 15 frames a second off the main thread, and pauses while the app is in the
 * background, animations are off, or Battery Saver is on.
 */
@Composable
internal fun HeaderWashBackdrop(modifier: Modifier = Modifier, fadeHeight: Dp = 380.dp) {
    val appearance = LocalAppearance.current
    val store = LocalAppearanceStore.current
    if (!appearance.hasActiveTexture || store == null) return
    val dayIso = store.dayIso()
    val dark = LocalSeptenaDarkTheme.current
    val accent = FruitAccents.resolve(appearance.accentId).color(dark)
    val seed = remember(dayIso) { HeaderWashSeeds.dailySeed(dayIso) }
    val canAnimate = rememberMotionAllowed()
    val animate = appearance.isSlowDrift && canAnimate
    var accumulatedPhase by remember { mutableDoubleStateOf(0.0) }

    BoxWithConstraints(modifier = modifier.fillMaxWidth().height(fadeHeight + 24.dp)) {
        val widthDp = maxWidth.value
        val heightDp = maxHeight.value
        val scale = min(LocalDensity.current.density, 2f)
        fun params(phase: Double) = HeaderWashParams(
            style = appearance.texture,
            isDark = dark,
            accent = accent,
            intensity = appearance.textureIntensity,
            seed = seed,
            phase = phase,
            fadeHeight = fadeHeight.value,
            mini = false,
        )

        val bitmap = if (animate) {
            var frame by remember { mutableStateOf<ImageBitmap?>(null) }
            LaunchedEffect(appearance, dark, seed, widthDp, heightDp, scale) {
                val buffers = HeaderWashBuffers()
                val start = System.nanoTime()
                val base = accumulatedPhase
                try {
                    while (isActive) {
                        val phase = base + (System.nanoTime() - start) / 1e9
                        frame = withContext(Dispatchers.Default) {
                            buffers.render(params(phase), widthDp, heightDp, scale)
                        }
                        delay(FRAME_INTERVAL_MS)
                    }
                } finally {
                    accumulatedPhase = base + (System.nanoTime() - start) / 1e9
                }
            }
            frame
        } else {
            val still = params(accumulatedPhase)
            produceState<ImageBitmap?>(null, still, widthDp, heightDp, scale) {
                value = withContext(Dispatchers.Default) {
                    HeaderWashBitmapCache.image(still, widthDp, heightDp, scale)
                }
            }.value
        }

        Canvas(modifier = Modifier.fillMaxSize()) {
            bitmap?.let { drawImage(it, dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt())) }
        }
    }
}

/** Small still Header Wash for the Settings texture tiles (iPhone `HeaderWashPreviewCanvas`). */
@Composable
internal fun HeaderWashPreview(
    style: String,
    dark: Boolean,
    accent: Color,
    intensity: Int,
    seed: Int,
    modifier: Modifier = Modifier,
) {
    if (style == AppearanceState.TEXTURE_NONE) return
    BoxWithConstraints(modifier = modifier) {
        val widthDp = maxWidth.value
        val heightDp = maxHeight.value
        val scale = min(LocalDensity.current.density, 2f)
        val params = HeaderWashParams(
            style = style,
            isDark = dark,
            accent = accent,
            intensity = max(55, intensity),
            seed = seed,
            phase = 0.0,
            fadeHeight = max(heightDp, 44f),
            mini = true,
        )
        val bitmap by produceState<ImageBitmap?>(null, params, widthDp, heightDp, scale) {
            value = withContext(Dispatchers.Default) { HeaderWashBitmapCache.image(params, widthDp, heightDp, scale) }
        }
        Canvas(modifier = Modifier.fillMaxSize()) {
            bitmap?.let { drawImage(it, dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt())) }
        }
    }
}

/** False while the system says not to animate: animations off, Battery Saver, or the app not in front. */
@Composable
private fun rememberMotionAllowed(): Boolean {
    val context = LocalContext.current
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val powerManager = remember(context) { context.getSystemService(PowerManager::class.java) }
    var powerSave by remember { mutableStateOf(powerManager?.isPowerSaveMode == true) }
    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                powerSave = powerManager?.isPowerSaveMode == true
            }
        }
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        onDispose { context.unregisterReceiver(receiver) }
    }
    val animatorScale = remember(lifecycleState) {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
    }
    return lifecycleState.isAtLeast(Lifecycle.State.RESUMED) && !powerSave && animatorScale > 0f
}

private const val FRAME_INTERVAL_MS = 1000L / 15

/** Renders one wash into a new bitmap at [pixelsPerDp] pixels per dp. */
private fun renderHeaderWash(params: HeaderWashParams, widthDp: Float, heightDp: Float, pixelsPerDp: Float): ImageBitmap? {
    val pw = max(1, (widthDp * pixelsPerDp).roundToInt())
    val ph = max(1, (heightDp * pixelsPerDp).roundToInt())
    if (pw > 4096 || ph > 4096) return null
    return ImageBitmap(pw, ph).also { drawInto(it, params, widthDp, heightDp, pixelsPerDp, clear = false) }
}

private fun drawInto(
    bitmap: ImageBitmap,
    params: HeaderWashParams,
    widthDp: Float,
    heightDp: Float,
    pixelsPerDp: Float,
    clear: Boolean,
) {
    val size = Size(bitmap.width.toFloat(), bitmap.height.toFloat())
    CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, androidx.compose.ui.graphics.Canvas(bitmap), size) {
        if (clear) drawRect(Color.Transparent, topLeft = Offset.Zero, size = size, blendMode = BlendMode.Clear)
        scale(pixelsPerDp, pixelsPerDp, pivot = Offset.Zero) {
            with(HeaderWashEngine) { drawHeaderWash(Size(widthDp, heightDp), params) }
        }
    }
}

/**
 * Three bitmaps in rotation for Slow drift: the frame on screen is never the
 * one being drawn, and no frame allocates a new bitmap.
 */
private class HeaderWashBuffers {
    private val buffers = arrayOfNulls<ImageBitmap>(3)
    private var next = 0

    fun render(params: HeaderWashParams, widthDp: Float, heightDp: Float, scale: Float): ImageBitmap? {
        val pw = max(1, (widthDp * scale).roundToInt())
        val ph = max(1, (heightDp * scale).roundToInt())
        if (pw > 4096 || ph > 4096) return null
        val existing = buffers[next]
        val bitmap = if (existing != null && existing.width == pw && existing.height == ph) {
            drawInto(existing, params, widthDp, heightDp, scale, clear = true)
            existing
        } else {
            renderHeaderWash(params, widthDp, heightDp, scale)?.also { buffers[next] = it }
        }
        next = (next + 1) % buffers.size
        return bitmap
    }
}

/** Bounded cache of still washes, so lists and Settings tiles blit a bitmap. */
private object HeaderWashBitmapCache {
    private data class Key(val params: HeaderWashParams, val pixelWidth: Int, val pixelHeight: Int)

    private const val MAX_ENTRIES = 24
    private val cache = object : LinkedHashMap<Key, ImageBitmap>(MAX_ENTRIES, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, ImageBitmap>?): Boolean = size > MAX_ENTRIES
    }

    fun image(params: HeaderWashParams, widthDp: Float, heightDp: Float, scale: Float): ImageBitmap? {
        val key = Key(params, max(1, (widthDp * scale).roundToInt()), max(1, (heightDp * scale).roundToInt()))
        synchronized(cache) { cache[key] }?.let { return it }
        val bitmap = renderHeaderWash(params, widthDp, heightDp, scale) ?: return null
        synchronized(cache) { cache[key] = bitmap }
        return bitmap
    }
}
