import java.net.URI
import java.security.MessageDigest
import java.util.zip.ZipInputStream

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The shared core's native libraries (ADR 0025, C1 #247), from the release
// that core/release/release.json pins, checked against its SHA-256. Nothing is
// built from Rust here. The libraries land in src/main/jniLibs (gitignored).
val fetchCoreJniLibs = tasks.register("fetchCoreJniLibs") {
    val manifest = rootProject.file("../core/release/release.json")
    val outDir = file("src/main/jniLibs")
    inputs.file(manifest)
    outputs.dir(outDir)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val release = groovy.json.JsonSlurper().parse(manifest) as Map<String, Any?>
        @Suppress("UNCHECKED_CAST")
        val asset = (release["assets"] as List<Map<String, Any?>>)
            .first { (it["name"] as String).startsWith("septena-core-android-jnilibs-") }
        val bytes = URI(asset["url"] as String).toURL().readBytes()
        val sum = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        check(sum == asset["sha256"]) { "core jniLibs checksum mismatch: $sum" }
        outDir.deleteRecursively()
        ZipInputStream(bytes.inputStream()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                if (entry.isDirectory || !entry.name.endsWith(".so")) continue
                val target = File(outDir, entry.name.substringAfter("jniLibs/"))
                check(target.canonicalPath.startsWith(outDir.canonicalPath)) { "bad zip entry ${entry.name}" }
                target.parentFile.mkdirs()
                target.outputStream().use { zip.copyTo(it) }
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(fetchCoreJniLibs) }

android {
    namespace = "app.septena.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "app.septena.android"
        minSdk = 29
        targetSdk = 36
        // CI passes the commit count, so each APK updates the one before it.
        versionCode = (findProperty("septenaBuildNumber") as String?)?.toInt() ?: 1
        versionName = "0.1.0"
    }

    // The fixed tester key (scripts/android-tester-keystore.sh). android.yml
    // passes the keystore path with -PseptenaTesterStoreFile and the password
    // as ORG_GRADLE_PROJECT_septenaTesterStorePassword, so it never shows on a
    // command line. Android updates an app only from an APK with the same key;
    // the runner's own debug key changes on every run. Local builds without
    // the key keep the machine's debug key.
    val testerStoreFile = findProperty("septenaTesterStoreFile") as String?
    signingConfigs {
        if (testerStoreFile != null) {
            create("tester") {
                storeFile = file(testerStoreFile)
                storeType = "pkcs12"
                storePassword = findProperty("septenaTesterStorePassword") as String?
                keyAlias = "septena-tester"
                keyPassword = findProperty("septenaTesterStorePassword") as String?
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.findByName("tester") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // JNA with its Android dispatch library, for the shared core's bindings.
    implementation("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")
    implementation(project(":core"))
    implementation(project(":store"))
    implementation(project(":transport"))
    implementation(project(":ui"))
    implementation(libs.sqldelight.android.driver)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)

    testImplementation(libs.junit)
}
