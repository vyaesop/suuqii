import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_version.g.dart';

/// The app's semantic version (e.g. "0.1.0"), sent to the backend as the
/// `X-App-Version` header on every request.
///
/// `main.dart` resolves the real value from `PackageInfo.fromPlatform()`
/// *before* the `ProviderContainer` is built and overrides this provider, so
/// no request can ever race the async platform lookup. The fallback below only
/// exists for tests/tools that build a container without the override.
@Riverpod(keepAlive: true)
String appVersion(AppVersionRef ref) => '0.0.0';
