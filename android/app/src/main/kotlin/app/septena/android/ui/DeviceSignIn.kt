package app.septena.android.ui

import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.android.auth.AccountSwitchChoice
import app.septena.android.auth.AccountSwitchSummary
import app.septena.android.signIn
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue
import app.septena.transport.DeviceCode
import app.septena.transport.DevicePollResult
import app.septena.transport.SignInQr
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private sealed interface SignInStep {
    data object Start : SignInStep
    data object Requesting : SignInStep
    data class ShowCode(val device: DeviceCode) : SignInStep
    data class Failed(val message: String) : SignInStep

    /** The user kept this device's tasks and asked for a backup: the export, then the start button again. */
    data object Exporting : SignInStep
}

/**
 * The open account-switch question (#575). It lives outside [SignInStep]: the sign-in coroutine waits on
 * [answer], and a step change would restart the effect that runs it.
 */
private class AccountSwitchQuestion(
    val summary: AccountSwitchSummary,
    val answer: CompletableDeferred<AccountSwitchChoice> = CompletableDeferred(),
)

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

/** surfaces.json `accountSwitch`: the question before another account replaces this device's tasks. */
private val accountSwitch: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["accountSwitch"] as? JsonValue.ObjectValue

/** The ids of surfaces.json `accountSwitch.copy`. */
@Suppress("EnumEntryName")
internal enum class AccountSwitchCopy { body, tasksOne, tasksOther, unsentOne, unsentOther, export, replace, cancel }

/** The account-switch question's title (surfaces.json `accountSwitch.title`), localized. */
internal fun accountSwitchTitle(languageTag: String): String =
    registryText(accountSwitch?.fields?.get("title").stringValue(), languageTag)

/** One line of surfaces.json `accountSwitch.copy`, localized. */
internal fun accountSwitchCopy(id: AccountSwitchCopy, languageTag: String): String {
    val entries = (accountSwitch?.fields?.get("copy") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id.name }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

/** The question's message: what goes, then how much of it. Same lines as Apple `SeptaskAccountSwitchPrompt`. */
internal fun accountSwitchMessage(summary: AccountSwitchSummary, languageTag: String): String {
    fun count(one: AccountSwitchCopy, other: AccountSwitchCopy, n: Int) =
        if (n == 1) accountSwitchCopy(one, languageTag) else accountSwitchCopy(other, languageTag).replace("{count}", n.toString())
    val lines = mutableListOf(accountSwitchCopy(AccountSwitchCopy.body, languageTag))
    lines += count(AccountSwitchCopy.tasksOne, AccountSwitchCopy.tasksOther, summary.tasks)
    if (summary.unsent > 0) lines += count(AccountSwitchCopy.unsentOne, AccountSwitchCopy.unsentOther, summary.unsent)
    return lines.joinToString("\n\n")
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
    var question by remember { mutableStateOf<AccountSwitchQuestion?>(null) }
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
                                    // Another account's session waits here for the user's answer (#575).
                                    val declined = graph.signIn(result.tokens) { summary ->
                                        val asked = AccountSwitchQuestion(summary)
                                        question = asked
                                        try {
                                            asked.answer.await()
                                        } finally {
                                            question = null
                                        }
                                    }
                                    // In here: signing in removes this panel, which cancels what follows.
                                    if (declined == null) graph.sync.requestSync()
                                    declined
                                }
                            }.onSuccess { declined ->
                                // Not signed in: the device keeps its tasks and the panel starts over.
                                when (declined) {
                                    null -> Unit
                                    AccountSwitchChoice.ExportFirst -> step = SignInStep.Exporting
                                    else -> step = SignInStep.Start
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
            // Settings is out of reach while signed out, so the export renders here (Apple opens Import & Export).
            SignInStep.Exporting -> {
                DataTransferSection(graph, languageTag)
                Button(onClick = { step = SignInStep.Requesting }) { Text(startTitle) }
            }
        }
    }

    question?.let { asked -> AccountSwitchDialog(asked, languageTag) }
}

/**
 * The account-switch question as a Material alert. Three answers do not fit one button row, so they stack,
 * in Apple's order: Export a Backup First, Replace (destructive), Cancel. Dismissing the dialog is Cancel,
 * which keeps this device's tasks.
 */
@Composable
private fun AccountSwitchDialog(asked: AccountSwitchQuestion, languageTag: String) {
    fun answer(choice: AccountSwitchChoice) {
        asked.answer.complete(choice)
    }
    AlertDialog(
        onDismissRequest = { answer(AccountSwitchChoice.Cancel) },
        title = { Text(accountSwitchTitle(languageTag)) },
        text = { Text(accountSwitchMessage(asked.summary, languageTag)) },
        confirmButton = {
            Column(modifier = Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
                TextButton(onClick = { answer(AccountSwitchChoice.ExportFirst) }) {
                    Text(accountSwitchCopy(AccountSwitchCopy.export, languageTag))
                }
                TextButton(onClick = { answer(AccountSwitchChoice.Replace) }) {
                    Text(accountSwitchCopy(AccountSwitchCopy.replace, languageTag), color = MaterialTheme.colorScheme.error)
                }
                TextButton(onClick = { answer(AccountSwitchChoice.Cancel) }) {
                    Text(accountSwitchCopy(AccountSwitchCopy.cancel, languageTag))
                }
            }
        },
    )
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
