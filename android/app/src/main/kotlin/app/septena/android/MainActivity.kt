package app.septena.android

import android.content.Intent
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
import app.septena.android.ui.SeptenaAndroidTheme
import app.septena.android.ui.SignInScreen
import app.septena.android.ui.TaskHomeScreen
import app.septena.android.widgets.SeptenaWidgetIntents
import app.septena.android.widgets.WidgetLaunchAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val graph by lazy { (application as SeptenaAndroidApp).graph }
    private val pendingWidgetAction = MutableStateFlow<WidgetLaunchAction?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        graph.prewarm()
        SeptenaWidgetIntents.parseLaunchAction(intent)?.let { pendingWidgetAction.value = it }
        setContent {
            SeptenaAndroidTheme(graph.appearance) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
                    val firstRun by graph.firstRun.phase.collectAsStateWithLifecycle()
                    val widgetAction by pendingWidgetAction.collectAsStateWithLifecycle()
                    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { graph.firstRun.resolve(graph) } }
                    when (firstRun) {
                        FirstRunState.Phase.Unresolved -> Box(
                            Modifier.fillMaxSize().safeDrawingPadding(),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator()
                        }
                        FirstRunState.Phase.Show -> Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                            FirstRunScreen(graph)
                        }
                        FirstRunState.Phase.Hidden -> if (signedIn) {
                            TaskHomeScreen(
                                graph = graph,
                                launchAction = widgetAction,
                                onConsumeLaunchAction = { pendingWidgetAction.value = null },
                            )
                        } else {
                            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                                SignInScreen(graph)
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        SeptenaWidgetIntents.parseLaunchAction(intent)?.let { pendingWidgetAction.value = it }
    }

    /** Opens live WebSocket nudges + foreground fallback polling and pulls immediately. */
    override fun onStart() {
        super.onStart()
        graph.doing.requestRefresh()
        graph.liveSync.onActivityStarted()
    }

    /** Closes the live socket and pauses polling while backgrounded (with a brief rotation grace window). */
    override fun onStop() {
        graph.liveSync.onActivityStopped()
        super.onStop()
    }
}
