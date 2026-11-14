import java.util.Properties

pluginManagement {
    val localProps = Properties()
    val localPropsFile = file("local.properties")
    if (localPropsFile.exists()) {
        localPropsFile.inputStream().use { localProps.load(it) }
    }
    val flutterHome = localProps.getProperty("flutter.sdk")
        ?: error("Missing flutter.sdk entry inside android/local.properties")

    includeBuild("$flutterHome/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

rootProject.name = "locashare_android"
include(":app")
