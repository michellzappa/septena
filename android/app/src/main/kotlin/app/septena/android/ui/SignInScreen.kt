package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph

/**
 * The signed-out screen once the first run is done: sign in by device approval ([DeviceSignInPanel]).
 * All copy comes from surfaces.json `deviceSignIn`.
 */
@Composable
fun SignInScreen(graph: AndroidAppGraph) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(deviceSignInTitle(languageTag), style = MaterialTheme.typography.headlineMedium)
        Text(deviceSignInCopy("intro", languageTag))
        DeviceSignInPanel(graph, languageTag)
    }
}
