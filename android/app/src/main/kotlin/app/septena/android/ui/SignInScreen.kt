package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph

/**
 * The signed-out screen once the first run is done: every way in this device offers ([SignInMethodsPanel]):
 * an email code when the server has it on, and device approval. Copy comes from sign-in.json and
 * surfaces.json `deviceSignIn`. [joining]: an invite link waits for the sign-in.
 */
@Composable
fun SignInScreen(graph: AndroidAppGraph, joining: Boolean = false) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    Column(
        // Scrolls: after an account-switch backup the panel also holds the export rows.
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(signInText(languageTag, "copy", "heading"), style = MaterialTheme.typography.headlineMedium)
        if (joining) Text(sharingCopy(SharingCopy.signInFirst, languageTag))
        SignInMethodsPanel(graph, languageTag, deviceIntro = deviceSignInCopy("intro", languageTag))
    }
}
