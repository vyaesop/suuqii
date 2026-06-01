import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/recipe_item.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'recipes_repository.g.dart';

class RecipesRepository {
  RecipesRepository({
    required this.db,
    required this.syncWorker,
    required this.shopId,
    required this.suppliesRepo,
  });

  final AppDatabase db;
  final SyncWorker syncWorker;
  final String shopId;
  final SuppliesRepository suppliesRepo;

  /// Returns a live stream of raw (unenriched) recipe items.
  /// Use [getForProduct] when you need supply names and costs; that
  /// does one enrichment pass rather than a full-table supply load on
  /// every stream emission.
  Stream<List<RecipeItem>> watchForProduct(String productId) {
    return db.recipesDao.watchForProduct(productId);
  }

  Future<List<RecipeItem>> getForProduct(String productId) async {
    final items = await db.recipesDao.getForProduct(productId);
    return _enrichWithSupplyInfo(items);
  }

  /// Calculates the total ingredient cost for one unit of this product.
  Future<Decimal> costForProduct(String productId) async {
    final items = await getForProduct(productId);
    var total = Decimal.zero;
    for (final item in items) {
      total += item.lineCost;
    }
    return total;
  }

  /// Atomically replace the recipe for a product and enqueue a sync event.
  Future<void> setRecipe({
    required String productId,
    required List<({String supplyId, Decimal quantity})> lines,
    String? ownerChallengeToken,
  }) async {
    final now = DateTime.now().toUtc();
    final items = lines
        .map(
          (l) => RecipeItem(
            id: const Uuid().v4(),
            shopId: shopId,
            productId: productId,
            supplyId: l.supplyId,
            quantity: l.quantity,
          ),
        )
        .toList();

    await db.transaction(() async {
      await db.recipesDao.setRecipe(productId, items);
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'recipe.set',
              occurredAt: now,
              payload: jsonEncode({
                'product_id': productId,
                'items': items
                    .map(
                      (i) => {
                        'id': i.id,
                        'supply_id': i.supplyId,
                        'quantity': i.quantity.toString(),
                      },
                    )
                    .toList(),
                if (ownerChallengeToken != null)
                  'owner_challenge': ownerChallengeToken,
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  Future<List<RecipeItem>> _enrichWithSupplyInfo(
    List<RecipeItem> items,
  ) async {
    if (items.isEmpty) return items;
    final supplies = await suppliesRepo.getAll();
    final supplyMap = {for (final s in supplies) s.id: s};
    return items.map((item) {
      final supply = supplyMap[item.supplyId];
      return RecipeItem(
        id: item.id,
        shopId: item.shopId,
        productId: item.productId,
        supplyId: item.supplyId,
        quantity: item.quantity,
        supplyName: supply?.name,
        supplyUnit: supply?.unit,
        supplyCostPerUnit: supply?.costPerUnit,
      );
    }).toList();
  }
}

@Riverpod(keepAlive: true)
RecipesRepository recipesRepository(RecipesRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('RecipesRepository requires authenticated user');
  }
  return RecipesRepository(
    db: ref.watch(appDatabaseProvider),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    suppliesRepo: ref.watch(suppliesRepositoryProvider),
  );
}
