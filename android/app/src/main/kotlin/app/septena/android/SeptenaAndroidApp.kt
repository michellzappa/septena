package app.septena.android

import android.app.Application
import app.cash.sqldelight.driver.android.AndroidSqliteDriver
import app.septena.core.SystemDayClock
import app.septena.core.TaskMutator
import app.septena.core.UuidTaskIdGenerator
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase

class SeptenaAndroidApp : Application() {
    val graph: AndroidAppGraph by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidAppGraph(this)
    }
}

class AndroidAppGraph(application: Application) {
    private val driver = AndroidSqliteDriver(
        schema = SeptenaDatabase.Schema,
        context = application,
        name = "septena-android.db",
    )
    val taskStore = SqlDelightTaskStore(driver)
    val clock = SystemDayClock()
    val ids = UuidTaskIdGenerator()
    val taskMutator = TaskMutator(taskStore, clock, ids)
}
