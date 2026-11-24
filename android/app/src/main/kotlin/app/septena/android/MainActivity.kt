package app.septena.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.ui.FirstRunScreen
import app.septena.android.ui.SignInScreen
import app.septena.android.ui.TaskHomeScreen
import app.septena.android.ui.SeptenaAndroidTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val graph by lazy { (application as SeptenaAndroidApp).graph }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SeptenaAndroidTheme {
                Surface(modifier = Modifier.safeDrawingPadding()) {
                    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
                    val firstRun by graph.firstRun.phase.collectAsStateWithLifecycle()
                    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { graph.firstRun.resolve(graph) } }
                    when (firstRun) {
                        FirstRunState.Phase.Unresolved -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator()
                        }
                        FirstRunState.Phase.Show -> FirstRunScreen(graph)
                        FirstRunState.Phase.Hidden -> if (signedIn) TaskHomeScreen(graph) else SignInScreen(graph)
                    }
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
