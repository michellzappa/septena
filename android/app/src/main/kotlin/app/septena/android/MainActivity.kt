package app.septena.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import app.septena.android.ui.TaskHomeScreen
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val graph = (application as SeptenaAndroidApp).graph
        setContent {
            MaterialTheme {
                Surface {
                    TaskHomeScreen(graph)
                }
            }
        }
    }
}
