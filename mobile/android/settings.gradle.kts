pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")

// The one NDK every module builds against. Keep in sync with
// app/build.gradle.kts.
val ndk = "28.2.13676358"

// Flutter 3.24.0's plugin loader doesn't inject the flutter extension into
// library subprojects. Newer packages (jni 0.14.x, package_info_plus 9.x, etc.)
// expect `flutter.compileSdkVersion`, `flutter.ndkVersion`, etc. to be
// available. This stub registers those values before each subproject is evaluated.
class FlutterExtensionStub(val ndkVersion: String) {
    val compileSdkVersion: Int = 36
    val minSdkVersion: Int = 21
    val targetSdkVersion: Int = 36
    val versionCode: String = "1"
    val versionName: String = "1.0"
}

gradle.beforeProject {
    if (name != "app") {
        extra["flutter"] = FlutterExtensionStub(ndk)

        // Some plugins ignore the stub and hardcode an NDK of their own —
        // jni 0.14.2 pins 27.0.12077973 — which makes Gradle download a second
        // NDK just for that module. Registering the override here, before the
        // module's own build script runs, means this callback fires after the
        // script has set its version but before the Android plugin reads it.
        afterEvaluate {
            extensions.findByName("android")?.withGroovyBuilder {
                setProperty("ndkVersion", ndk)
            }
        }
    }
}
