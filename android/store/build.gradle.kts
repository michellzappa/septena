import org.gradle.api.tasks.JavaExec

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
    testImplementation(libs.sqldelight.jvm.driver)
}

val runConformanceVectors = tasks.register<JavaExec>("runConformanceVectors") {
    dependsOn(tasks.named("testClasses"))
    classpath = sourceSets.getByName("test").runtimeClasspath
    mainClass.set("app.septena.store.StoreConformanceTestRunner")
    workingDir = projectDir
}

tasks.named("test") {
    dependsOn(runConformanceVectors)
    enabled = false
}

sqldelight {
    databases {
        create("SeptenaDatabase") {
            packageName.set("app.septena.store.db")
            dialect("app.cash.sqldelight:sqlite-3-24-dialect:${libs.versions.sqldelight.get()}")
        }
    }
}
