package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.android.auth.AccountSwitchChoice
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySignInMethodIds
import app.septena.core.stringValue
import app.septena.transport.EmailStartResult
import app.septena.transport.EmailVerifyResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The methods this client draws itself today (ADR 0047). Google and Apple come with #640; until then they
 * stay hidden, so the screen never shows a dead button.
 */
private val IMPLEMENTED_METHODS = setOf(RegistrySignInMethodIds.EMAIL, RegistrySignInMethodIds.DEVICE)

/** An answer from `GET /v1/auth/methods` later than this counts as a failure: device approval only. */
private const val METHODS_TIMEOUT_MS = 10_000L

/** The longest an email start or verify request may run before the form shows the network error. */
private const val EMAIL_REQUEST_TIMEOUT_MS = 30_000L

/** registry/sign-in.json (ADR 0047, docs/SIGN_IN_SURFACES_SPEC.md §3). */
private val signInRegistry: JsonValue.ObjectValue
    get() = RegistryCatalog.document("sign-in")

/** A string from sign-in.json at [path] (object keys), localized; empty when missing. */
internal fun signInText(languageTag: String, vararg path: String): String {
    var node: JsonValue? = signInRegistry
    for (key in path) node = (node as? JsonValue.ObjectValue)?.fields?.get(key)
    return registryText(node.stringValue(), languageTag)
}

private fun signInMethod(id: String): JsonValue.ObjectValue? =
    (signInRegistry.fields["methods"] as? JsonValue.ArrayValue)?.values
        ?.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id } as? JsonValue.ObjectValue

/** A method's button title (sign-in.json `methods[].title`), localized. */
internal fun signInMethodTitle(id: String, languageTag: String): String =
    registryText(signInMethod(id)?.fields?.get("title").stringValue(), languageTag)

/** sign-in.json `order.android` without the methods whose android flow is `none`. */
internal fun signInRegistryOrder(platform: String = RegistryPlatformIds.ANDROID): List<String> {
    val order = (signInRegistry.fields["order"] as? JsonValue.ObjectValue)?.fields?.get(platform) as? JsonValue.ArrayValue
    return order?.values.orEmpty().mapNotNull { it.stringValue() }.filter { id ->
        val flow = (signInMethod(id)?.fields?.get("flows") as? JsonValue.ObjectValue)?.fields?.get(platform).stringValue()
        flow != null && flow != "none"
    }
}

/**
 * The methods the sign-in screen shows, in registry order: the registry offers it on Android, the server
 * has it on ([serverMethods], from `GET /v1/auth/methods`), and this client implements it. A failed or
 * empty answer (null) shows device approval only, as before email sign-in existed.
 */
internal fun visibleSignInMethods(
    registryOrder: List<String>,
    serverMethods: Set<String>?,
    implemented: Set<String> = IMPLEMENTED_METHODS,
): List<String> {
    val fallback = registryOrder.filter { it == RegistrySignInMethodIds.DEVICE }
    if (serverMethods == null) return fallback
    return registryOrder.filter { it in serverMethods && it in implemented }.ifEmpty { fallback }
}

/**
 * Every way in this device offers, from sign-in.json: the email code above "I use Septena on another
 * device" when the server has email on, else device approval only. The sign-in screen and the first run's
 * account step both show it. [deviceStartTitle] and [deviceIntro] label device approval when it is the only
 * way in, as before. Callers watch `credentials.signedIn` for the result.
 */
@Composable
internal fun SignInMethodsPanel(
    graph: AndroidAppGraph,
    languageTag: String,
    deviceStartTitle: String = deviceSignInCopy("start", languageTag),
    deviceIntro: String? = null,
) {
    var methods by remember { mutableStateOf<List<String>?>(null) }
    LaunchedEffect(Unit) {
        val serverMethods = try {
            withTimeoutOrNull(METHODS_TIMEOUT_MS) { graph.auth.signInMethods() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        methods = visibleSignInMethods(signInRegistryOrder(), serverMethods)
    }

    val shown = methods
    if (shown == null) {
        CircularProgressIndicator()
        return
    }
    val showsEmail = RegistrySignInMethodIds.EMAIL in shown
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (showsEmail) Text(signInText(languageTag, "copy", "subheading"))
        for (id in shown) {
            when (id) {
                RegistrySignInMethodIds.EMAIL -> EmailSignInPanel(graph, languageTag)
                RegistrySignInMethodIds.DEVICE -> {
                    if (!showsEmail) deviceIntro?.let { Text(it) }
                    DeviceSignInPanel(
                        graph = graph,
                        languageTag = languageTag,
                        startTitle = if (showsEmail) signInMethodTitle(id, languageTag) else deviceStartTitle,
                        secondary = showsEmail,
                    )
                }
            }
        }
        // Email creates an account, so the Terms line stands under it (ADR 0047, #564).
        if (showsEmail) SignInTermsLine(languageTag)
    }
}

private sealed interface EmailStep {
    data object Address : EmailStep
    data class Code(val email: String, val codeLength: Int, val expiresAtMillis: Long) : EmailStep

    /** The user kept this device's tasks and asked for a backup: the export, then Send code again. */
    data object Exporting : EmailStep
}

/**
 * Sign-in by a code sent by email (#169): address, Send code, the code, Sign in. A new address creates an
 * account. Every request ends on success, failure or [EMAIL_REQUEST_TIMEOUT_MS]; a code that outlives its
 * lifetime shows the expired error. Copy and errors come from sign-in.json `email` and `errors`.
 */
@Composable
private fun EmailSignInPanel(graph: AndroidAppGraph, languageTag: String) {
    var step by remember { mutableStateOf<EmailStep>(EmailStep.Address) }
    var email by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var question by remember { mutableStateOf<AccountSwitchQuestion?>(null) }
    val scope = rememberCoroutineScope()

    fun errorText(id: String) = signInText(languageTag, "errors", id)

    /** Runs one request under the timeout; null on a network failure or the timeout. */
    suspend fun <T> request(call: suspend () -> T): T? = try {
        withTimeout(EMAIL_REQUEST_TIMEOUT_MS) { call() }
    } catch (_: TimeoutCancellationException) {
        null
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    fun send(address: String) {
        val trimmed = address.trim()
        if (!looksLikeEmail(trimmed)) {
            message = errorText("invalidEmail")
            return
        }
        busy = true
        message = null
        scope.launch {
            val result = request { graph.auth.startEmail(trimmed) }
            busy = false
            when (result) {
                is EmailStartResult.Sent -> {
                    code = ""
                    step = EmailStep.Code(trimmed, result.codeLength, System.currentTimeMillis() + result.expiresInSeconds * 1000L)
                }
                EmailStartResult.InvalidEmail -> message = errorText("invalidEmail")
                is EmailStartResult.RateLimited -> message = errorText("rateLimited")
                // 503 (email off, or the email did not go out) reads as "can't reach Septena": try again later.
                is EmailStartResult.Unavailable, null -> message = errorText("network")
            }
        }
    }

    fun verify(current: EmailStep.Code) {
        if (code.length != current.codeLength || busy) return
        if (System.currentTimeMillis() > current.expiresAtMillis) {
            message = errorText("codeExpired")
            return
        }
        busy = true
        message = null
        scope.launch {
            when (val result = request { graph.auth.verifyEmail(current.email, code) }) {
                is EmailVerifyResult.SignedIn -> {
                    val declined = try {
                        completeSignIn(graph, result.tokens) { question = it }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        busy = false
                        message = errorText("network")
                        return@launch
                    }
                    busy = false
                    // Not signed in: the device keeps its tasks. The code is spent, so the form starts over.
                    when (declined) {
                        null -> Unit
                        AccountSwitchChoice.ExportFirst -> step = EmailStep.Exporting
                        else -> step = EmailStep.Address
                    }
                }
                is EmailVerifyResult.WrongCode -> {
                    busy = false
                    code = ""
                    message = signInPlural("wrongCode", result.attemptsLeft, languageTag)
                }
                EmailVerifyResult.Expired -> {
                    busy = false
                    message = errorText("codeExpired")
                }
                EmailVerifyResult.TooManyAttempts -> {
                    busy = false
                    message = errorText("tooManyTries")
                }
                null -> {
                    busy = false
                    message = errorText("network")
                }
            }
        }
    }

    // The code's lifetime is a wait too: when it passes, say so.
    LaunchedEffect(step) {
        val current = step as? EmailStep.Code ?: return@LaunchedEffect
        delay((current.expiresAtMillis - System.currentTimeMillis()).coerceAtLeast(0L))
        message = errorText("codeExpired")
    }

    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when (val current = step) {
            EmailStep.Address -> {
                OutlinedTextField(
                    value = email,
                    onValueChange = {
                        email = it
                        message = null
                    },
                    label = { Text(signInText(languageTag, "email", "emailLabel")) },
                    placeholder = { Text(signInText(languageTag, "email", "emailPlaceholder")) },
                    singleLine = true,
                    enabled = !busy,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Email,
                        imeAction = ImeAction.Send,
                        autoCorrectEnabled = false,
                    ),
                    keyboardActions = KeyboardActions(onSend = { if (!busy) send(email) }),
                    modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.EmailAddress },
                )
                Button(onClick = { send(email) }, enabled = !busy && email.isNotBlank()) {
                    Text(signInText(languageTag, "email", "sendCode"))
                }
            }
            is EmailStep.Code -> {
                Text(signInText(languageTag, "email", "codeSent").replace("{email}", current.email))
                OutlinedTextField(
                    value = code,
                    onValueChange = { typed ->
                        code = typed.filter(Char::isDigit).take(current.codeLength)
                        message = null
                    },
                    label = { Text(signInText(languageTag, "email", "codeLabel")) },
                    singleLine = true,
                    enabled = !busy,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { verify(current) }),
                    modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
                )
                Button(onClick = { verify(current) }, enabled = !busy && code.length == current.codeLength) {
                    // A sign-in.json `email` copy key, not the first-run action id it happens to equal.
                    Text(signInText(languageTag, "email", "signIn")) // septena-lint:allow registry-id-literal
                }
                TextButton(onClick = { send(current.email) }, enabled = !busy) {
                    Text(signInText(languageTag, "email", "resend"))
                }
                TextButton(
                    onClick = {
                        code = ""
                        message = null
                        step = EmailStep.Address
                    },
                    enabled = !busy,
                ) {
                    Text(signInText(languageTag, "email", "differentEmail"))
                }
            }
            // Settings is out of reach while signed out, so the export renders here, as in device approval.
            EmailStep.Exporting -> {
                DataTransferSection(graph, languageTag)
                Button(onClick = { send(email) }, enabled = !busy) {
                    Text(signInText(languageTag, "email", "sendCode"))
                }
            }
        }
        if (busy) CircularProgressIndicator()
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }

    question?.let { asked -> AccountSwitchDialog(asked, languageTag) }
}

/** A plural error from sign-in.json `errors` (`{one, other}`), localized, with `{count}` filled. */
private fun signInPlural(id: String, count: Int, languageTag: String): String {
    val errors = signInRegistry.fields["errors"] as? JsonValue.ObjectValue
    val label = errors?.fields?.get(id) as? JsonValue.ObjectValue ?: return ""
    return registryPlural(label, count, languageTag)
}

/** A loose shape check before the server's own: something@something.something, no spaces. */
internal fun looksLikeEmail(text: String): Boolean {
    val at = text.indexOf('@')
    return at > 0 && at == text.lastIndexOf('@') && text.none(Char::isWhitespace) &&
        text.indexOf('.', at + 2) in (at + 2) until text.length - 1
}

/** sign-in.json `copy.terms` with its two links (plans.json `legal`). */
@Composable
private fun SignInTermsLine(languageTag: String) {
    val template = signInText(languageTag, "copy", "terms")
    val links = listOf(
        "{terms}" to (signInText(languageTag, "copy", "termsLabel") to plansText(languageTag, "legal", "terms")),
        "{privacy}" to (signInText(languageTag, "copy", "privacyLabel") to plansText(languageTag, "legal", "privacy")),
    )
    val style = TextLinkStyles(SpanStyle(textDecoration = TextDecoration.Underline))
    val text = buildAnnotatedString {
        var rest = template
        while (rest.isNotEmpty()) {
            val next = links.mapNotNull { link -> rest.indexOf(link.first).takeIf { it >= 0 }?.let { it to link } }
                .minByOrNull { it.first }
            if (next == null) {
                append(rest)
                break
            }
            val (index, link) = next
            val (label, url) = link.second
            append(rest.substring(0, index))
            if (url.isBlank()) append(label) else withLink(LinkAnnotation.Url(url, style)) { append(label) }
            rest = rest.substring(index + link.first.length)
        }
    }
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
