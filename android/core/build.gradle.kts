import org.gradle.api.tasks.JavaExec

plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // The shared core (ADR 0025, C1 #247). The bindings in
    // src/main/kotlin/app/septena/sharedcore are generated (scripts/core-pin.sh).
    // Each host brings its own JNA: the Android app the AAR, a JVM host the jar.
    compileOnly(libs.jna)
    testImplementation(libs.jna)
}

val runConformanceVectors = tasks.register<JavaExec>("runConformanceVectors") {
    dependsOn(tasks.named("testClasses"))
    classpath = sourceSets.getByName("test").runtimeClasspath
    mainClass.set("app.septena.core.ConformanceTestRunner")
    workingDir = projectDir
}

tasks.named("test") {
    dependsOn(runConformanceVectors)
    enabled = false
}
