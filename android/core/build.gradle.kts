import org.gradle.api.tasks.JavaExec

plugins {
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(17)
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
