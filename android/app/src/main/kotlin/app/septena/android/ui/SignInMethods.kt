package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.auth.AccountSwitchChoice
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySignInMethodIds
import app.septena.core.stringValue
import app.septena.transport.AuthMethodEntry
import app.septena.transport.EmailStartResult
import app.septena.transport.EmailVerifyResult
import app.septena.transport.OidcRedeemResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The methods this client draws without capability flags (kept for [visibleSignInMethods] tests).
 * OIDC providers (`google`, `apple`, `microsoft`) are also supported via [visibleSignInMethodsFromEntries]
 * whenever the server reports `web = true`.
 */
private val IMPLEMENTED_METHODS = setOf(RegistrySignInMethodIds.EMAIL, RegistrySignInMethodIds.DEVICE)
private val OIDC_PROVIDER_IDS = setOf(
    RegistrySignInMethodIds.GOOGLE,
    RegistrySignInMethodIds.APPLE,
    RegistrySignInMethodIds.MICROSOFT,
)
internal const val ANDROID_OIDC_CALLBACK_URL = "septask://auth/callback"

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

internal fun signInMethod(id: String): JsonValue.ObjectValue? =
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
 * The methods the sign-in screen shows, from `GET /v1/auth/methods` entries (including web OIDC providers).
 */
internal fun visibleSignInMethodsFromEntries(
    registryOrder: List<String>,
    serverEntries: List<AuthMethodEntry>?,
): List<String> {
    val fallback = registryOrder.filter { it == RegistrySignInMethodIds.DEVICE }
    if (serverEntries == null) return fallback
    val byId = serverEntries.associateBy { it.id }
    return registryOrder.filter { id ->
        val entry = byId[id] ?: return@filter false
        when (id) {
            in OIDC_PROVIDER_IDS -> entry.web
            RegistrySignInMethodIds.EMAIL, RegistrySignInMethodIds.DEVICE -> true
            else -> false
        }
    }.ifEmpty { fallback }
}

/**
 * Every way in this device offers, from sign-in.json: enabled OIDC providers (Google, Apple, Microsoft),
 * email code, and "I use Septena on another device" in Android registry order. Callers watch
 * `credentials.signedIn` for the result.
 */
@Composable
internal fun SignInMethodsPanel(
    graph: AndroidAppGraph,
    languageTag: String,
    deviceStartTitle: String = deviceSignInCopy("start", languageTag),
    deviceIntro: String? = null,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var methods by remember { mutableStateOf<List<String>?>(null) }
    var oidcBusy by remember { mutableStateOf(false) }
    var oidcError by remember { mutableStateOf<String?>(null) }
    var collision by remember { mutableStateOf<OidcRedeemResult.AccountExists?>(null) }
    var question by remember { mutableStateOf<AccountSwitchQuestion?>(null) }
    val pendingOidc by graph.pendingOidcCallback.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        val entries = try {
            withTimeoutOrNull(METHODS_TIMEOUT_MS) { graph.auth.signInMethodEntries() }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
        methods = visibleSignInMethodsFromEntries(signInRegistryOrder(), entries)
    }

    // Redeem `septask://auth/callback?oidc_code=...` when returning from the browser.
    LaunchedEffect(pendingOidc) {
        val cb = pendingOidc ?: return@LaunchedEffect
        graph.pendingOidcCallback.value = null
        if (cb.error != null) {
            if (cb.error != "cancelled" && cb.error != "access_denied") {
                oidcError = signInText(languageTag, "errors", "network")
            }
            return@LaunchedEffect
        }
        val code = cb.code ?: return@LaunchedEffect
        oidcBusy = true
        oidcError = null
        try {
            when (val res = withTimeout(EMAIL_REQUEST_TIMEOUT_MS) { graph.auth.redeemOidcSignIn(code) }) {
                is OidcRedeemResult.SignedIn -> {
                    completeSignIn(graph, res.tokens) { question = it }
                }
                is OidcRedeemResult.AccountExists -> {
                    collision = res
                }
                OidcRedeemResult.Expired -> {
                    oidcError = signInText(languageTag, "errors", "codeExpired")
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            oidcError = signInText(languageTag, "errors", "network")
        } finally {
            oidcBusy = false
        }
    }

    val shown = methods
    if (shown == null || oidcBusy) {
        CircularProgressIndicator()
        return
    }
    val activeCollision = collision
    if (activeCollision != null) {
        CollisionLinkPanel(
            graph = graph,
            languageTag = languageTag,
            collision = activeCollision,
            onCancel = { collision = null },
            onQuestion = { question = it },
        )
        question?.let { asked -> AccountSwitchDialog(asked, languageTag) }
        return
    }

    val hasPrimary = shown.any { it != RegistrySignInMethodIds.DEVICE }
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (hasPrimary) Text(signInText(languageTag, "copy", "subheading"))
        oidcError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        for (id in shown) {
            when (id) {
                in OIDC_PROVIDER_IDS -> {
                    OutlinedButton(
                        onClick = {
                            oidcError = null
                            openUrl(context, graph.auth.oidcStartUrl(id, ANDROID_OIDC_CALLBACK_URL))
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(signInMethodTitle(id, languageTag))
                    }
                }
                RegistrySignInMethodIds.EMAIL -> EmailSignInPanel(graph, languageTag)
                RegistrySignInMethodIds.DEVICE -> {
                    if (!hasPrimary) deviceIntro?.let { Text(it) }
                    DeviceSignInPanel(
                        graph = graph,
                        languageTag = languageTag,
                        startTitle = if (hasPrimary) signInMethodTitle(id, languageTag) else deviceStartTitle,
                        secondary = hasPrimary,
                    )
                }
            }
        }
        // Any account-creating method shows the Terms line under it (ADR 0047, #564).
        if (hasPrimary) SignInTermsLine(languageTag)
    }
    question?.let { asked -> AccountSwitchDialog(asked, languageTag) }
}

/** No-silent-linking collision step (ADR 0047 decision 5). */
@Composable
private fun CollisionLinkPanel(
    graph: AndroidAppGraph,
    languageTag: String,
    collision: OidcRedeemResult.AccountExists,
    onCancel: () -> Unit,
    onQuestion: (AccountSwitchQuestion?) -> Unit,
) {
    var code by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val providerName = signInMethod(collision.provider)?.fields?.get("name").stringValue()
        ?: collision.provider.replaceFirstChar { it.uppercase() }

    fun submit() {
        val token = collision.linkToken ?: return
        if (code.length != 6 || busy) return
        busy = true
        message = null
        scope.launch {
            val result = try {
                withTimeout(EMAIL_REQUEST_TIMEOUT_MS) { graph.auth.completeCollisionLink(token, code) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            when (result) {
                is EmailVerifyResult.SignedIn -> {
                    try {
                        completeSignIn(graph, result.tokens, onQuestion)
                        onCancel()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        message = signInText(languageTag, "errors", "network")
                    }
                }
                is EmailVerifyResult.WrongCode -> {
                    code = ""
                    message = signInPlural("wrongCode", result.attemptsLeft, languageTag)
                }
                EmailVerifyResult.Expired -> message = signInText(languageTag, "errors", "codeExpired")
                EmailVerifyResult.TooManyAttempts -> message = signInText(languageTag, "errors", "tooManyTries")
                null -> message = signInText(languageTag, "errors", "network")
            }
            busy = false
        }
    }

    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(signInText(languageTag, "existingAccount", "title"), style = MaterialTheme.typography.titleMedium)
        Text(
            signInText(languageTag, "existingAccount", "detail")
                .replace("{email}", collision.email)
                .replace("{provider}", providerName),
        )
        if (collision.linkToken != null) {
            OutlinedTextField(
                value = code,
                onValueChange = { typed ->
                    code = typed.filter(Char::isDigit).take(6)
                    message = null
                },
                label = { Text(signInText(languageTag, "email", "codeLabel")) },
                singleLine = true,
                enabled = !busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier.fillMaxWidth().semantics { contentType = ContentType.SmsOtpCode },
            )
            Button(onClick = ::submit, enabled = !busy && code.length == 6) {
                Text(signInText(languageTag, "email", "signIn")) // septena-lint:allow registry-id-literal
            }
        } else {
            Text(
                signInText(languageTag, "existingAccount", "manualDetail")
                    .replace("{email}", collision.email)
                    .replace("{provider}", providerName),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (busy) CircularProgressIndicator()
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        TextButton(onClick = onCancel, enabled = !busy) { Text(signInText(languageTag, "manage", "cancel")) }
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
