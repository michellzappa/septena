package app.septena.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.ui.SignInScreen
import app.septena.android.ui.TaskHomeScreen
import app.septena.android.ui.SeptenaAndroidTheme

class MainActivity : ComponentActivity() {
    private val graph by lazy { (application as SeptenaAndroidApp).graph }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SeptenaAndroidTheme {
                Surface(modifier = Modifier.safeDrawingPadding()) {
                    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
                    if (signedIn) TaskHomeScreen(graph) else SignInScreen(graph)
                }
            }
        }
    }

    /** Foreground fetch is the refresh path (no push yet), as on Apple. */
    override fun onStart() {
        super.onStart()
        if (graph.credentials.signedIn.value) graph.sync.requestSync()
    }
}
