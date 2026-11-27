pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    versionCatalogs {
        create("libs") { from(files("../android/gradle/libs.versions.toml")) }
    }
}

rootProject.name = "SeptenaWindows"
include(":core", ":store")
project(":core").projectDir = file("../android/core")
project(":store").projectDir = file("../android/store")
