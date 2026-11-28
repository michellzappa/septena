package app.septena.android

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Rational
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.core.util.Consumer
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import app.septena.android.ui.ChangeNotSavedDialog
import app.septena.android.ui.DoFloat
import app.septena.android.ui.FirstRunScreen
import app.septena.android.ui.SeptenaAndroidTheme
import app.septena.android.ui.SignInScreen
import app.septena.android.ui.TaskHomeScreen
import app.septena.android.widgets.SeptenaWidgetIntents
import app.septena.android.widgets.WidgetLaunchAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val graph by lazy { (application as SeptenaAndroidApp).graph }
    private val pendingWidgetAction = MutableStateFlow<WidgetLaunchAction?>(null)

    /** The Do floats in picture-in-picture (docs/DO_SPEC.md §4.2). */
    private var floating by mutableStateOf(false)
    private val canFloat by lazy { packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        graph.prewarm()
        SeptenaWidgetIntents.parseLaunchAction(intent)
            // A recreated activity still holds the link it opened with.
            ?.takeUnless { it is WidgetLaunchAction.JoinShare && savedInstanceState != null }
            ?.let { pendingWidgetAction.value = it }
        if (savedInstanceState == null) captureOidcCallback(intent)
        followDoFloat()
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
                                SignInScreen(graph, joining = widgetAction is WidgetLaunchAction.JoinShare)
                            }
                        }
                    }
                    // A write a sync could not save is never silent (#617).
                    if (signedIn) ChangeNotSavedDialog(graph.sync)
                    // Over the app, so the app keeps its state for the return.
                    if (floating) DoFloat(graph)
                }
            }
        }
    }

    /** Floats while this device shows the Do screen, and closes the float when the Do ends. */
    private fun followDoFloat() {
        if (!canFloat) return
        floating = isInPictureInPictureMode
        addOnPictureInPictureModeChangedListener(
            Consumer<PictureInPictureModeChangedInfo> { floating = it.isInPictureInPictureMode },
        )
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                graph.doing.ui.collect { ui ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        setPictureInPictureParams(floatParams().setAutoEnterEnabled(ui.isFullHere).build())
                    }
                    if (!ui.isFullHere && isInPictureInPictureMode) moveTaskToBack(false)
                }
            }
        }
    }

    private fun floatParams() = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))

    /** Android 12 and later enter by themselves (`setAutoEnterEnabled`). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && canFloat && graph.doing.ui.value.isFullHere) {
            enterPictureInPictureMode(floatParams().build())
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        SeptenaWidgetIntents.parseLaunchAction(intent)?.let { pendingWidgetAction.value = it }
        captureOidcCallback(intent)
    }

    private fun captureOidcCallback(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "septask" || data.host != "auth" || data.path != "/callback") return
        val code = data.getQueryParameter("oidc_code")
        val error = data.getQueryParameter("oidc_error")
        if (code != null || error != null) {
            graph.pendingOidcCallback.value = AndroidAppGraph.OidcCallback(code, error)
        }
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
