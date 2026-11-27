plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.jetbrains.compose)
    alias(libs.plugins.sqldelight) apply false
}

kotlin {
    jvmToolchain(17)
    // Compile the same portable task-list UI as Android without applying its SDK plugin.
    sourceSets["main"].kotlin.srcDir("../android/ui/src/commonMain/kotlin")
}

val sharedCore = project(":core")
val coreNatives = sharedCore.layout.buildDirectory.file("core-natives/septena-core-jvm-natives.jar")

dependencies {
    implementation(sharedCore)
    implementation(project(":store"))
    implementation(project(":transport"))
    implementation(libs.sqldelight.jvm.driver)
    implementation(libs.jna)
    implementation(libs.jna.platform)
    testImplementation(libs.junit)
    implementation(libs.kotlinx.coroutines.core)
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    runtimeOnly(files(coreNatives).builtBy(":core:fetchCoreJvmNatives"))
}

tasks.register<JavaExec>("smokeTest") {
    dependsOn(tasks.named("testClasses"))
    classpath = sourceSets["test"].runtimeClasspath
    mainClass.set("app.septena.windows.SpikeSmokeKt")
}

compose.desktop.application {
    mainClass = "app.septena.windows.MainKt"
    nativeDistributions {
        packageName = "SeptenaSpike"
        packageVersion = "0.1.0"
        includeAllModules = true
    }
}
