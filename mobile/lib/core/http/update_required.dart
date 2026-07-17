import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'update_required.g.dart';

/// Latched "the server requires a newer app" flag.
///
/// Set by the Dio interceptor when any API call returns HTTP 426 (Upgrade
/// Required). The router redirects to the blocking update screen while this
/// is true. It never resets within a session: only installing a newer build
/// (a fresh process with a higher X-App-Version) clears the condition.
@Riverpod(keepAlive: true)
class UpdateRequired extends _$UpdateRequired {
  @override
  bool build() => false;

  void markRequired() => state = true;
}
