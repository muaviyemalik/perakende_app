import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../core/database/local_product_dao.dart';
import '../core/providers/tenant_provider.dart';
import '../core/services/mutation_sync_engine.dart';
import '../core/services/product_sync_service.dart';
import '../core/utils/product_error_mapper.dart';

// Arka plan senkronizasyonunun oturum başına bir kez (veya invalidate olduğunda sonsuz döngüye girmeden)
// çalışmasını kontrol eden basit bir bayrak.
bool _hasSyncedThisSession = false;

/// Barkod ile ürün arar (Local-First)
///
/// Önce SQLite cache üzerinden arama yapar. Bulamazsa arka planda sync tetikleyip tekrar dener.
/// GÜVENLİK: isletme_id filtresi uygulanır.
final productByBarcodeProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, barcode) async {
  final isletmeId = await ref.watch(currentIsletmeIdProvider.future);
  if (isletmeId == null) return null;

  // 1. Önce Local Cache'ten oku
  var product = await LocalProductDao.instance.getByBarcode(
    barcode: barcode,
    isletmeId: isletmeId,
  );

  // 2. Ürün bulunamazsa online'da yeni eklenmiş olabilir, eşitlemeyi deneriz.
  if (product == null) {
    try {
      await ProductSyncService().syncProducts(isletmeId);
      // Senkronizasyon başarılı, tekrar dene
      product = await LocalProductDao.instance.getByBarcode(
        barcode: barcode,
        isletmeId: isletmeId,
      );
    } catch (e) {
      developer.log('productByBarcodeProvider sync error: $e');
      // İnternet yoksa veya hata varsa null kalmaya devam eder, local'deki son hali geçerlidir.
    }
  }

  return product?.toMap();
});

/// Tüm ürünleri listeler (Local-First)
///
/// Önce SQLite'dan okur. Cache boşsa sync işlemini bekler.
/// Cache doluysa UI'ı bekletmeden arkaplanda sync başlatır ve başarılı olursa provider'ı yeniler.
final allProductsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final isletmeId = await ref.watch(currentIsletmeIdProvider.future);
  if (isletmeId == null) return [];

  // 1. Önce lokalden okuruz
  var localProducts = await LocalProductDao.instance.getAllActive(isletmeId);

  if (localProducts.isEmpty) {
    // 2. Cache boşsa ve internet varsa (ilk kurulum), verileri çekmeyi bekleriz.
    try {
      await ProductSyncService().syncProducts(isletmeId);
      localProducts = await LocalProductDao.instance.getAllActive(isletmeId);
      _hasSyncedThisSession = true;
    } catch (e) {
      developer.log('allProductsProvider initial sync error: $e');
    }
  } else if (!_hasSyncedThisSession) {
    // 3. Cache dolu, arkaplanda sync başlat. (Fire-and-forget)
    _hasSyncedThisSession = true;
    Future.microtask(() async {
      try {
        await ProductSyncService().syncProducts(isletmeId);
        // Sync başarılı, UI'ı güncellemek için provider'ı invalidate ederiz.
        // Invalidate edildiğinde provider baştan çalışır, ancak _hasSyncedThisSession true olduğu için
        // tekrar arkaplan sync döngüsüne girmez. Sadece lokalden son veriyi okuyup hızlıca döner.
        ref.invalidateSelf();
      } catch (e) {
        developer.log('allProductsProvider background sync error: $e');
      }
    });
  }

  // UI'ın beklediği tipte (Map listesi) döndür (mevcut yapıyı bozmamak için)
  return localProducts.map((p) => p.toMap()).toList();
});

/// Ürün ekler (Local-First - Offline Mümkün)
final addProductProvider = Provider((ref) {
  return (Map<String, dynamic> data) async {
    final isletmeId = await ref.read(currentIsletmeIdProvider.future);
    if (isletmeId == null) throw Exception('İşletme bilgisi bulunamadı.');

    final name = data['name'] as String;
    final price = double.parse(data['price'].toString());
    final stock = int.parse(data['stock'].toString());
    final barcode = data['barcode'] as String?;

    try {
      await LocalProductDao.instance.createLocal(
        isletmeId: isletmeId,
        name: name,
        price: price,
        stock: stock,
        barcode: barcode,
      );
    } on DatabaseException catch (error) {
      if (isLocalTenantBarcodeUniqueViolation(error)) {
        throw const DuplicateProductBarcodeException();
      }
      rethrow;
    }

    // Sync engine tetikle
    MutationSyncEngine.instance.syncPendingMutations(isletmeId).then((_) {
      ref.invalidate(allProductsProvider);
      ref.invalidate(productByBarcodeProvider);
    });

    ref.invalidate(allProductsProvider);
    ref.invalidate(productByBarcodeProvider);
  };
});

/// Ürün günceller (Local-First - Offline Mümkün)
final updateProductProvider = Provider((ref) {
  return (String id, Map<String, dynamic> data) async {
    final isletmeId = await ref.read(currentIsletmeIdProvider.future);
    if (isletmeId == null) throw Exception('İşletme bilgisi bulunamadı.');

    final name = data['name'] as String;
    final price = double.parse(data['price'].toString());
    final stock = int.parse(data['stock'].toString());
    final barcode = data['barcode'] as String?;

    try {
      await LocalProductDao.instance.updateLocal(
        id: id,
        isletmeId: isletmeId,
        name: name,
        price: price,
        stock: stock,
        barcode: barcode,
      );
    } on DatabaseException catch (error) {
      if (isLocalTenantBarcodeUniqueViolation(error)) {
        throw const DuplicateProductBarcodeException();
      }
      rethrow;
    }

    // Sync engine tetikle
    MutationSyncEngine.instance.syncPendingMutations(isletmeId).then((_) {
      ref.invalidate(allProductsProvider);
      ref.invalidate(productByBarcodeProvider);
    });

    ref.invalidate(allProductsProvider);
    ref.invalidate(productByBarcodeProvider);
  };
});

/// Ürünü siler (Soft-Delete - Offline Mümkün)
final deleteProductProvider = Provider((ref) {
  return (String id) async {
    final isletmeId = await ref.read(currentIsletmeIdProvider.future);
    if (isletmeId == null) throw Exception('İşletme bilgisi bulunamadı.');

    await LocalProductDao.instance.softDeleteLocal(
      id: id,
      isletmeId: isletmeId,
    );

    // Sync engine tetikle
    MutationSyncEngine.instance.syncPendingMutations(isletmeId).then((_) {
      ref.invalidate(allProductsProvider);
      ref.invalidate(productByBarcodeProvider);
    });

    ref.invalidate(allProductsProvider);
    ref.invalidate(productByBarcodeProvider);
  };
});
