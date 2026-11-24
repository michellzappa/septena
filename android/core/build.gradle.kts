import org.gradle.api.tasks.JavaExec
import java.net.URI
import java.security.MessageDigest

plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
}

// The core's Linux and Windows natives for the JVM test runner (F3, #344):
// the jar from the release core/release/release.json pins, SHA-256 checked.
// JNA finds the library inside it on the classpath.
val coreJvmNatives = layout.buildDirectory.file("core-natives/septena-core-jvm-natives.jar")
val fetchCoreJvmNatives = tasks.register("fetchCoreJvmNatives") {
    val manifest = rootProject.file("../core/release/release.json")
    inputs.file(manifest)
    outputs.file(coreJvmNatives)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val release = groovy.json.JsonSlurper().parse(manifest) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val asset = (release["assets"] as List<Map<String, Any?>>)
            .first { (it["name"] as String).startsWith("septena-core-jvm-natives-") }
        val bytes = URI(asset["url"] as String).toURL().readBytes()
        val sum = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        check(sum == asset["sha256"]) { "core JVM natives checksum mismatch: $sum" }
        val out = coreJvmNatives.get().asFile
        out.parentFile.mkdirs()
        out.writeBytes(bytes)
    }
}

dependencies {
    testRuntimeOnly(files(coreJvmNatives).builtBy(fetchCoreJvmNatives))
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
