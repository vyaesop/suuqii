import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'connectivity_provider.g.dart';

@Riverpod(keepAlive: true)
Connectivity connectivity(ConnectivityRef ref) => Connectivity();

@Riverpod(keepAlive: true)
Stream<bool> onlineStatus(OnlineStatusRef ref) async* {
  final c = ref.watch(connectivityProvider);
  final initial = await c.checkConnectivity();
  yield !initial.contains(ConnectivityResult.none);
  await for (final r in c.onConnectivityChanged) {
    yield !r.contains(ConnectivityResult.none);
  }
}
