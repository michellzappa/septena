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
        // One version on every platform: MARKETING_VERSION in project.yml.
        versionName = Regex("MARKETING_VERSION: \"([^\"]+)\"")
            .find(rootProject.file("../project.yml").readText())!!.groupValues[1]
    }

    // Signing keys:
    // - Tester key (scripts/android-tester-keystore.sh): signs everyday CI debug
    //   and release APKs so tester phones can update in place.
    // - Centaur Labs release / Play upload keys (scripts/android-release-keystore.sh):
    //   passed by android-release.yml via -PseptenaReleaseStoreFile,
    //   -PseptenaReleaseKeyAlias (default "septena-release"), and
    //   ORG_GRADLE_PROJECT_septenaReleaseStorePassword (never on a command line).
    //   When present, release builds use this key; otherwise they fall back to
    //   the tester key (then debug) so android.yml and local builds stay unchanged.
    val testerStoreFile = findProperty("septenaTesterStoreFile") as String?
    val releaseStoreFile = findProperty("septenaReleaseStoreFile") as String?
    val releaseKeyAlias = (findProperty("septenaReleaseKeyAlias") as String?) ?: "septena-release"
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
        if (releaseStoreFile != null) {
            create("releaseDist") {
                storeFile = file(releaseStoreFile)
                storeType = "pkcs12"
                storePassword = findProperty("septenaReleaseStorePassword") as String?
                keyAlias = releaseKeyAlias
                keyPassword = (findProperty("septenaReleaseKeyPassword") as String?)
                    ?: (findProperty("septenaReleaseStorePassword") as String?)
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.findByName("tester") ?: signingConfigs.getByName("debug")
        }
        release {
            // R8 shrinking + ART-friendly optimization makes cold boot and Compose
            // scroll noticeably faster than debug. Uses the Centaur Labs release/upload
            // key when provided (android-release.yml), otherwise the tester key so
            // adb install -r updates an installed device build in place.
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = signingConfigs.findByName("releaseDist")
                ?: signingConfigs.findByName("tester")
                ?: signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Store native .so libraries uncompressed and page-aligned in APKs and AABs
    // (required for Android 15+ 16 KB page-size devices on Google Play).
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    // Keep all bundled widget/tile/shortcut locale strings in every Play split
    // so switching language in-app or on-device never drops localized labels.
    bundle {
        language {
            enableSplit = false
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
    implementation(libs.play.services.code.scanner)

    testImplementation(libs.junit)
}
