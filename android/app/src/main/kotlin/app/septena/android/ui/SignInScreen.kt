package app.septena.android.ui

import android.os.Build
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.transport.DeviceCode
import app.septena.transport.DevicePollResult
import kotlinx.coroutines.delay

private sealed interface SignInStep {
    data object Start : SignInStep
    data object Requesting : SignInStep
    data class ShowCode(val device: DeviceCode) : SignInStep
    data class Failed(val message: String) : SignInStep
}

/**
 * Sign-in by device approval (ADR 0016): this device shows a code and the user enters it in Septena on a
 * signed-in iPhone, iPad or Mac (Settings ▸ Account ▸ Approve a sign-in), which shows this device's name before
 * the user approves.
 */
@Composable
fun SignInScreen(graph: AndroidAppGraph) {
    var step by remember { mutableStateOf<SignInStep>(SignInStep.Start) }

    LaunchedEffect(step) {
        when (val current = step) {
            SignInStep.Requesting -> step = runCatching { graph.auth.startDevice(deviceName()) }
                .fold({ SignInStep.ShowCode(it) }, { SignInStep.Failed(it.message ?: "Could not reach Septena") })
            is SignInStep.ShowCode -> {
                val deadline = System.currentTimeMillis() + current.device.expiresInSeconds * 1000L
                while (System.currentTimeMillis() < deadline) {
                    delay(current.device.intervalSeconds.coerceAtLeast(2L) * 1000L)
                    val result = runCatching { graph.auth.pollDevice(current.device) }.getOrNull() ?: continue
                    when (result) {
                        DevicePollResult.Pending -> Unit
                        DevicePollResult.Expired -> break
                        is DevicePollResult.Approved -> {
                            graph.credentials.adopt(result.tokens)
                            graph.sync.requestSync()
                            return@LaunchedEffect
                        }
                    }
                }
                step = SignInStep.Failed("The code expired.")
            }
            else -> Unit
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Sign in to Septena", style = MaterialTheme.typography.headlineMedium)
        when (val current = step) {
            SignInStep.Start -> {
                Text("Use a device where Septena is already signed in.")
                Button(onClick = { step = SignInStep.Requesting }) { Text("Get a sign-in code") }
            }
            SignInStep.Requesting -> CircularProgressIndicator()
            is SignInStep.ShowCode -> {
                Text("On your iPhone, iPad or Mac, open Septena and go to Settings ▸ Account ▸ Approve a sign-in. Enter this code:")
                Text(
                    current.device.displayCode,
                    style = MaterialTheme.typography.displaySmall,
                    fontFamily = FontFamily.Monospace,
                )
                Text("The code works for 10 minutes. After you approve it, this screen continues by itself.")
                CircularProgressIndicator()
            }
            is SignInStep.Failed -> {
                Text(current.message)
                Button(onClick = { step = SignInStep.Requesting }) { Text("Get a new code") }
            }
        }
    }
}

/** Shown to the approving app; must match the backend's client-name pattern `[\w .()-]{1,40}`. */
private fun deviceName(): String {
    val raw = "Android ${Build.MODEL}".replace(Regex("[^\\w .()-]"), " ").trim()
    return raw.take(40).ifBlank { "Android" }
}
