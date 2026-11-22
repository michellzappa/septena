plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.sqldelight)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    implementation(libs.sqldelight.runtime)
}

sqldelight {
    databases {
        create("SeptenaDatabase") {
            packageName.set("app.septena.store.db")
            dialect("app.cash.sqldelight:sqlite-3-24-dialect:${libs.versions.sqldelight.get()}")
        }
    }
}
