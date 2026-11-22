// The Windows path of ADR 0013 / ADR 0025: Kotlin on the JVM loads the shared
// core's library through JNA. core.yml writes generated/ (the UniFFI Kotlin
// bindings) and sets SEPTENA_CORE_LIB_DIR and SEPTENA_CONFORMANCE.
plugins {
    kotlin("jvm") version "2.4.21"
    application
}

kotlin {
    jvmToolchain(17)
    sourceSets["main"].kotlin.srcDirs("src", "generated")
}

dependencies {
    implementation("net.java.dev.jna:jna:5.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}

application {
    mainClass = "app.septena.sharedcore.harness.MainKt"
}

tasks.named<JavaExec>("run") {
    systemProperty("jna.library.path", providers.environmentVariable("SEPTENA_CORE_LIB_DIR").get())
    args(providers.environmentVariable("SEPTENA_CONFORMANCE").get())
}
