import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/http/dio_client.dart';
import '../../../core/storage/app_database.dart';
import '../../auth/presentation/controllers/auth_controller.dart';
import '../../auth/domain/entities/auth_state.dart';
import '../domain/entities/product.dart';
import 'products_remote_data_source.dart';

part 'products_repository.g.dart';

class ProductsRepository {
  ProductsRepository({required this.db, required this.remote});
  final AppDatabase db;
  final ProductsRemoteDataSource remote;

  Stream<List<Product>> watch({String? query}) =>
      db.productsDao.watchAll(query: query);

  Future<Product?> byId(String id) => db.productsDao.getById(id);

  /// Pull fresh products from server, replace local cache.
  Future<int> refreshFromServer({required String shopId}) async {
    final remoteList = await remote.list(shopId: shopId);
    await db.productsDao.upsertAll(remoteList);
    return remoteList.length;
  }
}

@Riverpod(keepAlive: true)
ProductsRepository productsRepository(ProductsRepositoryRef ref) {
  return ProductsRepository(
    db: ref.watch(appDatabaseProvider),
    remote: ProductsRemoteDataSource(ref.watch(dioProvider)),
  );
}

@riverpod
Stream<List<Product>> watchProducts(WatchProductsRef ref, {String? query}) {
  return ref.watch(productsRepositoryProvider).watch(query: query);
}

/// One-shot refresh kicked off after login (and when user pulls to refresh).
@riverpod
class ProductsSync extends _$ProductsSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(productsRepositoryProvider).refreshFromServer(shopId: auth.shopId);
    });
  }
}
