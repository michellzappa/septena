package app.septena.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.icu.lang.UCharacter
import android.icu.lang.UProperty
import android.icu.text.BreakIterator
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.AvatarPhotoNotice
import app.septena.android.SeptenaAndroidApp
import app.septena.core.Avatar
import app.septena.core.JsonValue
import app.septena.core.PersonInitials
import app.septena.core.ProjectShare
import app.septena.core.RegistryCatalog
import app.septena.core.ShareMember
import app.septena.core.longValue
import app.septena.core.stringValue
import app.septena.ui.PersonSmallGlyph
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// The avatar (#857): how every avatar draws, and the editor behind Settings ▸ Account. All copy comes
// from surfaces.json `avatar`, the fills from tokens.json `avatarColors`. Same sheet as iPhone and Mac.

private val avatarSurface: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["avatar"] as? JsonValue.ObjectValue

/** The ids of surfaces.json `avatar.copy`. */
@Suppress("EnumEntryName")
internal enum class AvatarCopy {
    edit,
    photo,
    emoji,
    initials,
    color,
    choosePhoto,
    usePhoto,
    removePhoto,
    cropHint,
    emojiHint,
    initialsHint,
    save,
    cancel,
    photoPending,
    photoTooLarge,
    photoFailed,
}

/** One line of surfaces.json `avatar.copy`, localized. */
internal fun avatarCopy(id: AvatarCopy, languageTag: String): String {
    val entries = (avatarSurface?.fields?.get("copy") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id.name }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

private fun avatarTitle(languageTag: String): String =
    registryText(avatarSurface?.fields?.get("title").stringValue(), languageTag)

/** The editor's segments, in registry order (photo, emoji, initials). */
private fun avatarKinds(): List<String> =
    (avatarSurface?.fields?.get("kinds") as? JsonValue.ArrayValue)?.values.orEmpty()
        .mapNotNull { it.stringValue() }
        .filter { it in setOf(Avatar.KIND_PHOTO, Avatar.KIND_EMOJI, Avatar.KIND_INITIALS) }
        .ifEmpty { listOf(Avatar.KIND_PHOTO, Avatar.KIND_EMOJI, Avatar.KIND_INITIALS) }

private fun avatarNumber(key: String, fallback: Long): Long =
    avatarSurface?.fields?.get(key).longValue() ?: fallback

private val maxPhotoBytes: Long get() = avatarNumber("maxPhotoBytes", 262_144L)
private val photoSize: Int get() = avatarNumber("photoSize", 256L).toInt()
private val maxInitials: Int get() = avatarNumber("maxInitials", 3L).toInt()

/** One avatar fill: a single-color fruit accent of tokens.json, with its check ink for the initials. */
internal data class AvatarColor(
    val id: String,
    val name: String,
    val light: Color,
    val dark: Color,
    val inkLight: Color,
    val inkDark: Color,
) {
    fun fill(dark: Boolean): Color = if (dark) this.dark else light
    fun ink(dark: Boolean): Color = if (dark) inkDark else inkLight
}

internal object AvatarColors {
    /** tokens.json `avatarColors`: the fruit accents without the multicolor one (ADR 0019). */
    val all: List<AvatarColor> by lazy {
        val tokens = RegistryCatalog.document("tokens").fields
        (tokens["fruitAccents"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { raw ->
            val color = (raw as? JsonValue.ObjectValue)?.fields ?: return@mapNotNull null
            if ((color["multicolor"] as? JsonValue.BooleanValue)?.value == true) return@mapNotNull null
            runCatching {
                AvatarColor(
                    id = color["id"].stringValue() ?: return@mapNotNull null,
                    name = color["name"].stringValue().orEmpty(),
                    light = registryColor(color["light"]),
                    dark = registryColor(color["dark"]),
                    inkLight = registryColor(color["checkLight"]),
                    inkDark = registryColor(color["checkDark"]),
                )
            }.getOrNull()
        }
    }

    /** The fill of an account that never picked one, and of a member without an avatar. */
    val default: AvatarColor? by lazy {
        val id = ((RegistryCatalog.document("tokens").fields["avatarColors"] as? JsonValue.ObjectValue)
            ?.fields?.get("default")).stringValue()
        all.firstOrNull { it.id == id } ?: all.firstOrNull()
    }

    /** The palette entry for an id. A missing or unknown id is the default. */
    fun resolve(id: String?): AvatarColor? = byId(id) ?: default

    fun byId(id: String?): AvatarColor? = all.firstOrNull { it.id == id }
}

/**
 * One avatar circle: a photo clipped to the circle, else the emoji or initials in white on the palette
 * color. No avatar or an unknown color draws the default color (Persimmon).
 */
@Composable
internal fun AvatarCircle(
    avatar: Avatar?,
    name: String,
    photo: ImageBitmap?,
    size: Dp,
    modifier: Modifier = Modifier,
) {
    val dark = LocalSeptenaDarkTheme.current
    val palette = AvatarColors.resolve(avatar?.color)
    val fill = palette?.fill(dark)
    val ink = palette?.ink(dark) ?: MaterialTheme.colorScheme.onSurface
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(fill ?: MaterialTheme.colorScheme.surfaceContainerHighest, CircleShape),
    ) {
        if (photo != null && avatar?.showsPhoto == true) {
            Image(
                bitmap = photo,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(size).clip(CircleShape),
            )
        } else {
            val text = avatar?.text(name) ?: PersonInitials.of(name)
            if (text.isEmpty()) {
                PersonSmallGlyph(tint = ink, size = size * 0.46f)
            } else {
                val emoji = avatar?.showsEmoji == true
                Text(
                    text = text,
                    color = ink,
                    fontSize = (size.value * if (emoji) 0.5f else 0.4f).sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
        }
    }
}

/** A photo file as a bitmap, decoded off the main thread at about [targetPx]. */
@Composable
private fun rememberAvatarBitmap(file: File?, targetPx: Int): ImageBitmap? {
    val bitmap by produceState<ImageBitmap?>(null, file?.path, file?.lastModified()) {
        value = file?.let { withContext(Dispatchers.IO) { decodeFile(it, targetPx) } }
    }
    return bitmap
}

private fun decodeFile(file: File, targetPx: Int): ImageBitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    val options = BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, targetPx) }
    BitmapFactory.decodeFile(file.path, options)?.asImageBitmap()
}.getOrNull()

private fun sampleSize(width: Int, height: Int, targetPx: Int): Int {
    var sample = 1
    while (width / (sample * 2) >= targetPx && height / (sample * 2) >= targetPx) sample *= 2
    return sample
}

/** The account's avatar, from the cache on this device. */
@Composable
internal fun AccountAvatar(graph: AndroidAppGraph, name: String, size: Dp, modifier: Modifier = Modifier) {
    val avatar by graph.avatars.avatar.collectAsStateWithLifecycle()
    val file by graph.avatars.photo.collectAsStateWithLifecycle()
    val photo = rememberAvatarBitmap(file, targetPx = AVATAR_BITMAP_PX)
    AvatarCircle(avatar, name, photo, size, modifier)
}

/**
 * The account avatar on the Account page: a tap opens the editor. Signed out there is no account to
 * keep it, so it only shows. Opening the page reads the server's avatar again.
 */
@Composable
internal fun EditableAccountAvatar(graph: AndroidAppGraph, name: String, signedIn: Boolean, languageTag: String) {
    var editing by remember { mutableStateOf(false) }
    LaunchedEffect(signedIn) { if (signedIn) graph.avatars.refresh() }
    val label = avatarCopy(AvatarCopy.edit, languageTag)
    AccountAvatar(
        graph = graph,
        name = name,
        size = 64.dp,
        modifier = if (signedIn) {
            Modifier
                .clip(CircleShape)
                .clickable(onClickLabel = label, role = Role.Button) { editing = true }
                .semantics { contentDescription = label }
        } else {
            Modifier
        },
    )
    if (editing) AvatarEditorDialog(graph, name, languageTag, onDismiss = { editing = false })
}

/** A member of a shared project. A photo is fetched once per photo id. */
@Composable
internal fun MemberAvatar(share: ProjectShare, member: ShareMember, size: Dp) {
    val context = LocalContext.current
    val avatar = member.avatar
    val photoId = avatar?.photoId?.takeIf { avatar.showsPhoto }
    val bitmap by produceState<ImageBitmap?>(null, share.id, member.id, photoId) {
        if (photoId == null) return@produceState
        val graph = (context.applicationContext as SeptenaAndroidApp).graph
        val file = graph.avatars.memberPhoto(share.id, member.id, photoId) ?: return@produceState
        value = withContext(Dispatchers.IO) { decodeFile(file, AVATAR_BITMAP_PX) }
    }
    AvatarCircle(avatar, member.name, bitmap, size)
}

/**
 * Edit Avatar: one dialog with Photo, Emoji and Initials. Photo opens the system picker, then the
 * crop step; Emoji takes one emoji; Initials up to `avatar.maxInitials` letters. Emoji and Initials
 * pick a fill. Save keeps the edit on this device at once and sends it when online.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun AvatarEditorDialog(graph: AndroidAppGraph, name: String, languageTag: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val current by graph.avatars.avatar.collectAsStateWithLifecycle()
    val currentFile by graph.avatars.photo.collectAsStateWithLifecycle()
    val notice by graph.avatars.notice.collectAsStateWithLifecycle()
    val currentPhoto = rememberAvatarBitmap(currentFile, AVATAR_BITMAP_PX)
    fun copy(id: AvatarCopy) = avatarCopy(id, languageTag)

    val kinds = remember { avatarKinds() }
    val start = remember { current }
    var kind by remember { mutableStateOf(start?.kind?.takeIf { it in kinds } ?: Avatar.KIND_INITIALS) }
    var color by remember {
        mutableStateOf(AvatarColors.resolve(start?.color)?.id.orEmpty())
    }
    var emoji by remember { mutableStateOf(start?.emoji.orEmpty()) }
    var initials by remember { mutableStateOf(start?.initials.orEmpty()) }
    /** The picked image, while the crop step shows. */
    var cropping by remember { mutableStateOf<Bitmap?>(null) }
    /** The cropped JPEG, until Save. */
    var draftJpeg by remember { mutableStateOf<ByteArray?>(null) }
    var draftPhoto by remember { mutableStateOf<ImageBitmap?>(null) }
    var localNotice by remember { mutableStateOf<AvatarPhotoNotice?>(null) }
    var working by remember { mutableStateOf(false) }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val picked = withContext(Dispatchers.IO) { decodeUri(context, uri, MAX_SOURCE_PX) }
            if (picked == null) localNotice = AvatarPhotoNotice.Failed else cropping = picked
        }
    }

    val source = cropping
    if (source != null) {
        AvatarCropDialog(
            source = source,
            languageTag = languageTag,
            onCancel = { cropping = null },
            onUse = { jpeg ->
                cropping = null
                if (jpeg == null || jpeg.size > maxPhotoBytes) {
                    localNotice = AvatarPhotoNotice.TooLarge
                } else {
                    localNotice = null
                    draftJpeg = jpeg
                    draftPhoto = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)?.asImageBitmap()
                }
            },
        )
        return
    }

    val emojiValid = isOneEmoji(emoji)
    val preview: Avatar = when (kind) {
        Avatar.KIND_PHOTO -> Avatar(Avatar.KIND_PHOTO, color, initials.ifBlank { null }, photoId = PREVIEW_PHOTO_ID)
        Avatar.KIND_EMOJI -> Avatar(Avatar.KIND_EMOJI, color, initials.ifBlank { null }, emoji.takeIf { emojiValid })
        else -> Avatar(Avatar.KIND_INITIALS, color, initials.ifBlank { null })
    }
    val previewPhoto = draftPhoto ?: currentPhoto.takeIf { current?.showsPhoto == true }
    val canSave = !working && when (kind) {
        Avatar.KIND_PHOTO -> draftJpeg != null
        Avatar.KIND_EMOJI -> emojiValid
        else -> true
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(avatarTitle(languageTag)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                AvatarCircle(
                    avatar = preview,
                    name = name,
                    photo = previewPhoto,
                    size = 72.dp,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    kinds.forEachIndexed { index, value ->
                        SegmentedButton(
                            selected = kind == value,
                            onClick = { kind = value },
                            shape = SegmentedButtonDefaults.itemShape(index, kinds.size),
                        ) {
                            Text(copy(kindCopy(value)), maxLines = 1)
                        }
                    }
                }
                when (kind) {
                    Avatar.KIND_PHOTO -> {
                        TextButton(
                            enabled = !working,
                            onClick = {
                                picker.launch(PickVisualMediaRequest(mediaType = ActivityResultContracts.PickVisualMedia.ImageOnly))
                            },
                        ) { Text(copy(AvatarCopy.choosePhoto)) }
                        if (current?.showsPhoto == true && draftJpeg == null) {
                            TextButton(
                                enabled = !working,
                                onClick = {
                                    working = true
                                    scope.launch {
                                        graph.avatars.removePhoto()
                                        working = false
                                        kind = Avatar.KIND_INITIALS
                                    }
                                },
                            ) { Text(copy(AvatarCopy.removePhoto), color = MaterialTheme.colorScheme.error) }
                        }
                        (localNotice ?: notice)?.let { shown ->
                            Text(
                                copy(noticeCopy(shown)),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (shown == AvatarPhotoNotice.Pending) {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                } else {
                                    MaterialTheme.colorScheme.error
                                },
                            )
                        }
                    }
                    Avatar.KIND_EMOJI -> {
                        OutlinedTextField(
                            value = emoji,
                            onValueChange = { emoji = lastEmoji(it) ?: "" },
                            label = { Text(copy(AvatarCopy.emojiHint)) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        AvatarColorRow(color, languageTag) { color = it }
                    }
                    else -> {
                        OutlinedTextField(
                            value = initials,
                            onValueChange = { initials = cleanInitials(it) },
                            placeholder = { Text(copy(AvatarCopy.initialsHint)) },
                            label = { Text(copy(AvatarCopy.initials)) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        AvatarColorRow(color, languageTag) { color = it }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = canSave,
                onClick = {
                    working = true
                    scope.launch {
                        when (kind) {
                            Avatar.KIND_PHOTO -> draftJpeg?.let { graph.avatars.savePhoto(it) }
                            Avatar.KIND_EMOJI -> graph.avatars.save(Avatar.KIND_EMOJI, emoji, color, initials.trim())
                            else -> graph.avatars.save(Avatar.KIND_INITIALS, null, color, initials.trim())
                        }
                        working = false
                        onDismiss()
                    }
                },
            ) { Text(copy(AvatarCopy.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(copy(AvatarCopy.cancel)) } },
    )
}

/** One swatch per avatar color; the selected one wears the app's selection ring (AppearancePicker). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AvatarColorRow(selected: String, languageTag: String, onPick: (String) -> Unit) {
    val dark = LocalSeptenaDarkTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(avatarCopy(AvatarCopy.color, languageTag), style = MaterialTheme.typography.titleSmall)
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AvatarColors.all.forEach { swatch ->
                val isSelected = swatch.id == selected
                val label = registryText(swatch.name, languageTag)
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .border(
                            width = if (isSelected) 2.dp else 0.75.dp,
                            color = if (isSelected) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f)
                            },
                            shape = CircleShape,
                        )
                        .selectable(selected = isSelected, role = Role.RadioButton, onClick = { onPick(swatch.id) })
                        .clearAndSetSemantics { contentDescription = label }
                        .padding(4.dp)
                        .background(swatch.fill(dark), CircleShape),
                )
            }
        }
    }
}

/**
 * The crop step: the picked image under a circle mask. Drag moves it, pinch or the slider zooms it.
 * Use Photo hands back a square JPEG of `avatar.photoSize` pixels, or null when it could not be made.
 */
@Composable
private fun AvatarCropDialog(source: Bitmap, languageTag: String, onCancel: () -> Unit, onUse: (ByteArray?) -> Unit) {
    val scope = rememberCoroutineScope()
    val image = remember(source) { source.asImageBitmap() }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    var zoom by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var working by remember { mutableStateOf(false) }

    /** Image pixels to viewport pixels at zoom 1: the image covers the square. */
    fun baseScale(): Float {
        val side = viewport.width.toFloat()
        if (side <= 0f) return 1f
        return maxOf(side / source.width, side / source.height)
    }

    /** Keeps the image over the whole circle. */
    fun clamp(raw: Offset, atZoom: Float): Offset {
        val side = viewport.width.toFloat()
        val scale = baseScale() * atZoom
        val maxX = ((source.width * scale - side) / 2f).coerceAtLeast(0f)
        val maxY = ((source.height * scale - side) / 2f).coerceAtLeast(0f)
        return Offset(raw.x.coerceIn(-maxX, maxX), raw.y.coerceIn(-maxY, maxY))
    }

    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(avatarTitle(languageTag)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val ring = MaterialTheme.colorScheme.surface
                Canvas(
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(1f)
                        .clip(MaterialTheme.shapes.medium)
                        .onSizeChanged { viewport = it }
                        .pointerInput(source) {
                            detectTransformGestures { _, pan, zoomChange, _ ->
                                val next = (zoom * zoomChange).coerceIn(1f, MAX_ZOOM)
                                zoom = next
                                offset = clamp(offset + pan, next)
                            }
                        },
                ) {
                    val side = size.width
                    val scale = baseScale() * zoom
                    val drawnW = source.width * scale
                    val drawnH = source.height * scale
                    drawImage(
                        image = image,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(source.width, source.height),
                        dstOffset = IntOffset(
                            (side / 2f + offset.x - drawnW / 2f).toInt(),
                            (size.height / 2f + offset.y - drawnH / 2f).toInt(),
                        ),
                        dstSize = IntSize(drawnW.toInt(), drawnH.toInt()),
                    )
                    val circle = Path().apply {
                        addOval(androidx.compose.ui.geometry.Rect(Offset.Zero, size))
                    }
                    clipPath(circle, clipOp = ClipOp.Difference) {
                        drawRect(Color.Black.copy(alpha = 0.55f))
                    }
                    drawCircle(ring.copy(alpha = 0.9f), radius = side / 2f, style = Stroke(width = 1.5.dp.toPx()))
                }
                Slider(
                    value = zoom,
                    valueRange = 1f..MAX_ZOOM,
                    onValueChange = {
                        zoom = it
                        offset = clamp(offset, it)
                    },
                )
                Text(
                    avatarCopy(AvatarCopy.cropHint, languageTag),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !working && viewport.width > 0,
                onClick = {
                    working = true
                    val side = viewport.width.toFloat()
                    val scale = baseScale() * zoom
                    val at = offset
                    scope.launch {
                        val jpeg = withContext(Dispatchers.Default) { cropJpeg(source, side, scale, at) }
                        working = false
                        onUse(jpeg)
                    }
                },
            ) { Text(avatarCopy(AvatarCopy.usePhoto, languageTag)) }
        },
        dismissButton = { TextButton(onClick = onCancel) { Text(avatarCopy(AvatarCopy.cancel, languageTag)) } },
    )
}

/** Renders what the circle shows into a `photoSize` square JPEG under `maxPhotoBytes`. */
private fun cropJpeg(source: Bitmap, viewportPx: Float, scale: Float, offset: Offset): ByteArray? = runCatching {
    val out = photoSize
    val k = out / viewportPx
    val drawnW = source.width * scale * k
    val drawnH = source.height * scale * k
    val left = (viewportPx / 2f + offset.x) * k - drawnW / 2f
    val top = (viewportPx / 2f + offset.y) * k - drawnH / 2f
    val target = Bitmap.createBitmap(out, out, Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(target)
    canvas.drawColor(android.graphics.Color.WHITE)
    canvas.drawBitmap(source, null, RectF(left, top, left + drawnW, top + drawnH), Paint(Paint.FILTER_BITMAP_FLAG))
    var bytes: ByteArray? = null
    for (quality in JPEG_QUALITIES) {
        val stream = ByteArrayOutputStream()
        target.compress(Bitmap.CompressFormat.JPEG, quality, stream)
        bytes = stream.toByteArray()
        if (bytes.size <= maxPhotoBytes) break
    }
    target.recycle()
    bytes?.takeIf { it.size <= maxPhotoBytes }
}.getOrNull()

/** The picked image, upright and at most [maxPx] on its long side. */
private fun decodeUri(context: Context, uri: Uri, maxPx: Int): Bitmap? = runCatching {
    val resolver = context.contentResolver
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@runCatching null
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxPx) sample *= 2
    val decoded = resolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
    } ?: return@runCatching null
    val orientation = resolver.openInputStream(uri)?.use {
        ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    } ?: ExifInterface.ORIENTATION_NORMAL
    val matrix = Matrix()
    when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        else -> return@runCatching decoded
    }
    Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
}.getOrNull()

private fun kindCopy(kind: String): AvatarCopy = when (kind) {
    Avatar.KIND_PHOTO -> AvatarCopy.photo
    Avatar.KIND_EMOJI -> AvatarCopy.emoji
    else -> AvatarCopy.initials
}

private fun noticeCopy(notice: AvatarPhotoNotice): AvatarCopy = when (notice) {
    AvatarPhotoNotice.Pending -> AvatarCopy.photoPending
    AvatarPhotoNotice.TooLarge -> AvatarCopy.photoTooLarge
    AvatarPhotoNotice.Failed -> AvatarCopy.photoFailed
}

private fun graphemes(text: String): List<String> {
    val breaks = BreakIterator.getCharacterInstance()
    breaks.setText(text)
    val out = mutableListOf<String>()
    var start = breaks.first()
    var end = breaks.next()
    while (end != BreakIterator.DONE) {
        out += text.substring(start, end)
        start = end
        end = breaks.next()
    }
    return out
}

/** A pictograph, a flag or a keycap, as the backend's `isOneEmoji` reads it. */
private fun isEmojiGrapheme(grapheme: String): Boolean = grapheme.codePoints().anyMatch { cp ->
    cp == KEYCAP || (cp >= 0x80 && UCharacter.hasBinaryProperty(cp, UProperty.EMOJI))
}

private fun isOneEmoji(text: String): Boolean {
    val parts = graphemes(text)
    return text.length <= 64 && parts.size == 1 && isEmojiGrapheme(parts[0])
}

/** The field keeps one emoji: the last one typed or picked. */
private fun lastEmoji(input: String): String? = graphemes(input).lastOrNull(::isEmojiGrapheme)

/** Letters and digits only, uppercased, at most `avatar.maxInitials` of them. */
private fun cleanInitials(input: String): String {
    val kept = buildString {
        input.codePoints().forEach { cp ->
            val type = Character.getType(cp)
            val mark = type == Character.NON_SPACING_MARK.toInt() ||
                type == Character.COMBINING_SPACING_MARK.toInt() ||
                type == Character.ENCLOSING_MARK.toInt()
            if (Character.isLetterOrDigit(cp) || mark) appendCodePoint(cp)
        }
    }.uppercase()
    return graphemes(kept).take(maxInitials).joinToString("")
}

/** How many pixels an avatar bitmap needs: the largest circle is 72 dp. */
private const val AVATAR_BITMAP_PX = 256
/** The long side of the picked image the crop step works on. */
private const val MAX_SOURCE_PX = 2048
private const val MAX_ZOOM = 4f
private const val KEYCAP = 0x20E3
private val JPEG_QUALITIES = listOf(85, 75, 60)
/** The preview's photo id: the preview draws the photo it is handed. */
private const val PREVIEW_PHOTO_ID = "preview"
