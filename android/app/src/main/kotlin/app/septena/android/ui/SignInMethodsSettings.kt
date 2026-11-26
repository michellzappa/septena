package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.generated.RegistrySignInMethodIds
import app.septena.transport.AccessHttpException
import app.septena.transport.AuthMethodEntry
import app.septena.transport.LinkedIdentities
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Settings ▸ Account ▸ Sign-in methods (ADR 0047 decision 6, #643): lists linked
 * methods on the signed-in account, lets the user add email or enabled OIDC
 * providers, and remove any method except the last one.
 */
@Composable
internal fun SignInMethodsSettingsSection(
    graph: AndroidAppGraph,
    signedIn: Boolean,
    languageTag: String,
) {
    if (!signedIn) return
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var linked by remember { mutableStateOf<LinkedIdentities?>(null) }
    var serverMethods by remember { mutableStateOf<List<AuthMethodEntry>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var showingAddEmail by remember { mutableStateOf(false) }
    val pendingOidc by graph.pendingOidcCallback.collectAsStateWithLifecycle()

    LaunchedEffect(signedIn) {
        loading = true
        error = null
        try {
            linked = graph.access.listIdentities()
            serverMethods = runCatching { graph.auth.signInMethodEntries() }.getOrDefault(emptyList())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            error = signInText(languageTag, "manage", "loadFailed")
        } finally {
            loading = false
        }
    }

    // Complete an OIDC provider link returning from `septask://auth/callback?oidc_code=...`.
    LaunchedEffect(pendingOidc) {
        val cb = pendingOidc ?: return@LaunchedEffect
        graph.pendingOidcCallback.value = null
        val code = cb.code ?: return@LaunchedEffect
        busy = true
        error = null
        status = null
        try {
            linked = graph.access.redeemOidcLink(code)
            status = signInText(languageTag, "manage", "added")
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (e: AccessHttpException) {
            error = if (e.errorCode == "already_linked") {
                signInText(languageTag, "manage", "alreadyLinked")
            } else {
                signInText(languageTag, "manage", "addFailed")
            }
        } catch (_: Exception) {
            error = signInText(languageTag, "manage", "addFailed")
        } finally {
            busy = false
        }
    }

    val linkedProviders = linked?.identities.orEmpty().map { it.provider }.toSet()
    val emailAvailable = serverMethods.any { it.id == RegistrySignInMethodIds.EMAIL }
    val addableOidc = listOf(
        RegistrySignInMethodIds.GOOGLE,
        RegistrySignInMethodIds.APPLE,
        RegistrySignInMethodIds.MICROSOFT,
    ).filter { id ->
        id !in linkedProviders && serverMethods.any { it.id == id && it.web }
    }.map { id ->
        val name = signInMethod(id)?.fields?.get("name").stringValue()
            ?: id.replaceFirstChar { it.uppercase() }
        id to name
    }

    Column(modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)) {
        Text(
            signInText(languageTag, "manage", "heading"),
            style = MaterialTheme.typography.titleSmall,
            modifier = Modifier.padding(start = 16.dp, top = 8.dp, bottom = 4.dp),
        )
        if (loading && linked == null) {
            CircularProgressIndicator(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
        linked?.identities.orEmpty().forEach { item ->
            ListItem(
                headlineContent = { Text(item.label) },
                trailingContent = if (linked?.canRemove == true) {
                    {
                        TextButton(
                            enabled = !busy,
                            onClick = {
                                busy = true
                                error = null
                                status = null
                                scope.launch {
                                    try {
                                        linked = graph.access.unlinkIdentity(item.id)
                                        status = signInText(languageTag, "manage", "removed")
                                    } catch (cancelled: CancellationException) {
                                        throw cancelled
                                    } catch (e: AccessHttpException) {
                                        error = if (e.errorCode == "last_method") {
                                            signInText(languageTag, "manage", "lastMethod")
                                        } else {
                                            signInText(languageTag, "manage", "removeFailed")
                                        }
                                    } catch (_: Exception) {
                                        error = signInText(languageTag, "manage", "removeFailed")
                                    } finally {
                                        busy = false
                                    }
                                }
                            },
                        ) {
                            Text(signInText(languageTag, "manage", "remove"), color = MaterialTheme.colorScheme.error)
                        }
                    }
                } else {
                    null
                },
            )
        }
        if (addableOidc.isNotEmpty() || emailAvailable) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                addableOidc.forEach { (id, name) ->
                    OutlinedButton(
                        enabled = !busy,
                        onClick = {
                            busy = true
                            error = null
                            status = null
                            scope.launch {
                                try {
                                    val url = graph.access.startLinkOidc(id, ANDROID_OIDC_CALLBACK_URL)
                                    openUrl(context, url)
                                } catch (cancelled: CancellationException) {
                                    throw cancelled
                                } catch (_: Exception) {
                                    error = signInText(languageTag, "manage", "addFailed")
                                } finally {
                                    busy = false
                                }
                            }
                        },
                    ) {
                        Text(signInText(languageTag, "manage", "addProvider").replace("{provider}", name))
                    }
                }
                if (emailAvailable) {
                    OutlinedButton(
                        enabled = !busy,
                        onClick = { showingAddEmail = true },
                    ) {
                        Text(signInText(languageTag, "manage", "addEmail"))
                    }
                }
            }
        }
        error?.let {
            Text(
                it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        status?.let {
            Text(
                it,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        Text(
            signInText(languageTag, "manage", "footer"),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }

    if (showingAddEmail) {
        LinkEmailDialog(
            graph = graph,
            languageTag = languageTag,
            onLinked = { updated ->
                linked = updated
                status = signInText(languageTag, "manage", "added")
                showingAddEmail = false
            },
            onDismiss = { showingAddEmail = false },
        )
    }
}

@Composable
private fun LinkEmailDialog(
    graph: AndroidAppGraph,
    languageTag: String,
    onLinked: (LinkedIdentities) -> Unit,
    onDismiss: () -> Unit,
) {
    var email by remember { mutableStateOf("") }
    var sentTo by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(signInText(languageTag, "manage", "addEmail")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val target = sentTo
                if (target == null) {
                    OutlinedTextField(
                        value = email,
                        onValueChange = { email = it; error = null },
                        label = { Text(signInText(languageTag, "email", "emailLabel")) },
                        placeholder = { Text(signInText(languageTag, "email", "emailPlaceholder")) },
                        singleLine = true,
                        enabled = !busy,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else {
                    Text(signInText(languageTag, "email", "codeSent").replace("{email}", target))
                    OutlinedTextField(
                        value = code,
                        onValueChange = { code = it.filter(Char::isDigit).take(6); error = null },
                        label = { Text(signInText(languageTag, "email", "codeLabel")) },
                        singleLine = true,
                        enabled = !busy,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (busy) CircularProgressIndicator()
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            }
        },
        confirmButton = {
            val target = sentTo
            if (target == null) {
                TextButton(
                    enabled = !busy && looksLikeEmail(email.trim()),
                    onClick = {
                        val trimmed = email.trim()
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                graph.access.startLinkEmail(trimmed)
                                sentTo = trimmed
                                code = ""
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                error = signInText(languageTag, "errors", "network")
                            } finally {
                                busy = false
                            }
                        }
                    },
                ) {
                    Text(signInText(languageTag, "email", "sendCode"))
                }
            } else {
                TextButton(
                    enabled = !busy && code.length == 6,
                    onClick = {
                        busy = true
                        error = null
                        scope.launch {
                            try {
                                onLinked(graph.access.verifyLinkEmail(target, code))
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (e: AccessHttpException) {
                                error = when (e.errorCode) {
                                    "already_linked" -> signInText(languageTag, "manage", "alreadyLinked")
                                    "invalid_code" -> signInText(languageTag, "errors", "tooManyTries")
                                    "expired_or_unknown" -> signInText(languageTag, "errors", "codeExpired")
                                    else -> signInText(languageTag, "errors", "network")
                                }
                                code = ""
                            } catch (_: Exception) {
                                error = signInText(languageTag, "errors", "network")
                            } finally {
                                busy = false
                            }
                        }
                    },
                ) {
                    Text(signInText(languageTag, "manage", "addEmail"))
                }
            }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onDismiss) { Text(signInText(languageTag, "manage", "cancel")) }
        },
    )
}
