# R8 / ProGuard rules for release builds (see build.gradle.kts).
#
# The Flutter Gradle plugin already injects its own keep rules for the engine
# and for plugin registrants; the rules here cover the standard Flutter
# recommendations plus what our plugin set needs.
#
# Plugin audit (pubspec.yaml):
#   sentry_flutter        -> sentry-android ships consumer ProGuard rules; nothing extra.
#   drift / sqlite3_flutter_libs -> pure Dart + prebuilt native lib; nothing extra.
#   connectivity_plus, shared_preferences, path_provider, image_picker,
#   flutter_secure_storage, cached_network_image, package_info_plus
#                         -> ship consumer rules or need none.

# Flutter wrapper (standard recommended keeps).
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# The Flutter engine references Play Core for deferred components; we don't
# use them, so silence the missing-class warnings instead of bundling Play Core.
-dontwarn com.google.android.play.core.**
