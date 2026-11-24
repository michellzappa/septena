package app.septena.android.ui

import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue
import app.septena.transport.DeviceCode
import app.septena.transport.DevicePollResult
import app.septena.transport.SignInQr
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private sealed interface SignInStep {
    data object Start : SignInStep
    data object Requesting : SignInStep
    data class ShowCode(val device: DeviceCode) : SignInStep
    data class Failed(val message: String) : SignInStep
}

/** surfaces.json `deviceSignIn`: the block that holds the sign-in-by-code copy. */
private val deviceSignIn: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["deviceSignIn"] as? JsonValue.ObjectValue

/** The sign-in screen's title (surfaces.json `deviceSignIn.title`), localized. */
internal fun deviceSignInTitle(languageTag: String): String =
    registryText(deviceSignIn?.fields?.get("title").stringValue(), languageTag)

/** One line of surfaces.json `deviceSignIn.copy` by id, localized. */
internal fun deviceSignInCopy(id: String, languageTag: String): String {
    val entries = (deviceSignIn?.fields?.get("copy") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

/**
 * Sign-in by device approval (ADR 0016): this device shows a code and the user enters it in Septena on a
 * signed-in iPhone, iPad or Mac (Settings ▸ Account ▸ Approve a sign-in), which shows this device's name before
 * the user approves. Used by the sign-in screen and by the first run's account step. [startTitle] labels the
 * first button. Callers watch `credentials.signedIn` for the result.
 */
@Composable
internal fun DeviceSignInPanel(
    graph: AndroidAppGraph,
    languageTag: String,
    startTitle: String = deviceSignInCopy("start", languageTag),
) {
    var step by remember { mutableStateOf<SignInStep>(SignInStep.Start) }
    val unreachable = deviceSignInCopy("unreachable", languageTag)
    val expired = deviceSignInCopy("expired", languageTag)

    LaunchedEffect(step) {
        when (val current = step) {
            SignInStep.Requesting -> step = runCatching { graph.auth.startDevice(deviceName()) }
                .fold({ SignInStep.ShowCode(it) }, { SignInStep.Failed(it.message ?: unreachable) })
            is SignInStep.ShowCode -> {
                val deadline = System.currentTimeMillis() + current.device.expiresInSeconds * 1000L
                while (System.currentTimeMillis() < deadline) {
                    delay(current.device.intervalSeconds.coerceAtLeast(2L) * 1000L)
                    val result = runCatching { graph.auth.pollDevice(current.device) }.getOrNull() ?: continue
                    when (result) {
                        DevicePollResult.Pending -> Unit
                        DevicePollResult.Expired -> break
                        is DevicePollResult.Approved -> {
                            runCatching {
                                withContext(Dispatchers.IO) {
                                    graph.credentials.adopt(result.tokens)
                                    // In here: signing in removes this panel, which cancels what follows.
                                    graph.sync.requestSync()
                                }
                            }.onFailure {
                                if (it is CancellationException) throw it
                                step = SignInStep.Failed(it.message ?: unreachable)
                            }
                            return@LaunchedEffect
                        }
                    }
                }
                step = SignInStep.Failed(expired)
            }
            else -> Unit
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when (val current = step) {
            SignInStep.Start -> Button(onClick = { step = SignInStep.Requesting }) { Text(startTitle) }
            SignInStep.Requesting -> CircularProgressIndicator()
            is SignInStep.ShowCode -> {
                Text(deviceSignInCopy("approve", languageTag))
                current.device.qr?.let { SignInQrImage(it) }
                Text(
                    current.device.displayCode,
                    style = MaterialTheme.typography.displaySmall,
                    fontFamily = FontFamily.Monospace,
                )
                Text(deviceSignInCopy("lifetime", languageTag))
                CircularProgressIndicator()
            }
            is SignInStep.Failed -> {
                Text(current.message)
                Button(onClick = { step = SignInStep.Requesting }) { Text(deviceSignInCopy("retry", languageTag)) }
            }
        }
    }
}

/**
 * The sign-in QR, drawn from the backend's module matrix. Black on white with the 4-module quiet zone in both
 * themes: not every scanner reads an inverted QR. The approving app reads the same code it would get typed.
 */
@Composable
private fun SignInQrImage(qr: SignInQr) {
    // Decorative for TalkBack: the same code is the text right below it.
    Canvas(modifier = Modifier.size(220.dp)) {
        val quiet = 4
        val module = size.minDimension / (qr.size + quiet * 2)
        drawRect(Color.White)
        for (row in 0 until qr.size) {
            for (col in 0 until qr.size) {
                if (!qr.isDark(row, col)) continue
                drawRect(
                    Color.Black,
                    topLeft = Offset((col + quiet) * module, (row + quiet) * module),
                    // A hair of overlap so no seam shows between neighbouring modules.
                    size = Size(module + 0.5f, module + 0.5f),
                )
            }
        }
    }
}

/** Shown to the approving app; must match the backend's client-name pattern `[\w .()-]{1,40}`. */
private fun deviceName(): String {
    val raw = "Android ${Build.MODEL}".replace(Regex("[^\\w .()-]"), " ").trim()
    // A wire value the server matches, not UI copy: it stays English.
    return raw.take(40).ifBlank { "Android" } // septena-lint:allow registry-owned-literal
}
