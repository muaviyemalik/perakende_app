import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/local_product_dao.dart';
import '../database/sync_metadata_dao.dart';
import 'mutation_sync_engine.dart';

// =============================================================================
// ProductSyncService — Ürünleri Supabase'den SQLite'a Senkronize Eder
// =============================================================================
//
// AMAÇ:
//   Supabase'deki ürün değişikliklerini SQLite yerel veritabanına çeker.
//
// INCREMENTAL SYNC & PAGINATION:
//   - Yalnızca son başarılı sync tarihinden (last_successful_sync_at)
//     sonra güncellenmiş kayıtlar çekilir.
//   - PAGE_SIZE (500) limitleriyle sayfalama yapılır.
//   - Aynı updated_at değerindeki ürünleri kaçırmamak için 
//     (updated_at, id) cursor / tie-breaker mantığı uygulanır.
//
// GÜVENLİK:
//   Tüm sayfalar başarıyla indirilip SQLite'a yazılana kadar metadata 
//   güncellenmez. Hata anında yarıda kesilir ve son kalınan yer korunur.
// =============================================================================

class ProductSyncService {
  ProductSyncService({
    SupabaseClient? supabaseClient,
    LocalProductDao? productDao,
    SyncMetadataDao? metadataDao,
  })  : _supabaseClient = supabaseClient ?? Supabase.instance.client,
        _productDao = productDao ?? LocalProductDao.instance,
        _metadataDao = metadataDao ?? SyncMetadataDao.instance;

  final SupabaseClient _supabaseClient;
  final LocalProductDao _productDao;
  final SyncMetadataDao _metadataDao;

  static const _logTag = 'PRODUCT_SYNC_SERVICE';

  /// Supabase üzerinden ürünleri getirir ve yerel SQLite'a kaydeder (Incremental Sync).
  Future<void> syncProducts(int isletmeId) async {
    developer.log('Senkronizasyon başlatılıyor — isletme_id=$isletmeId', name: _logTag);

    try {
      // Önce PENDING durumdaki lokal değişiklikleri (mutasyonları) gönder.
      await MutationSyncEngine.instance.syncPendingMutations(isletmeId);

      final lastSync = await _metadataDao.getLastSyncedAt(
        isletmeId: isletmeId,
        entity: SyncEntityType.products,
      );

      const int pageSize = 500;
      bool hasMore = true;
      int totalSynced = 0;

      String? cursorUpdatedAtStr = lastSync?.toUtc().toIso8601String();
      String? cursorId;

      developer.log(
        lastSync != null 
            ? 'Incremental sync yapılıyor — son sync: $cursorUpdatedAtStr' 
            : 'Full sync (ilk senkronizasyon) yapılıyor', 
        name: _logTag
      );

      String? maxUpdatedAtStr = cursorUpdatedAtStr;

      while (hasMore) {
        final productsData = await fetchProductsPage(
          isletmeId,
          cursorUpdatedAtStr,
          cursorId,
          pageSize,
        );

        if (productsData.isEmpty) {
          hasMore = false;
          break;
        }

        final localProducts = productsData.map((map) => LocalProduct.fromApiMap(map)).toList();

        // Her sayfayı upsertBatch ile SQLite'a yaz
        await _productDao.upsertBatch(
          isletmeId: isletmeId,
          products: localProducts,
        );

        totalSynced += localProducts.length;

        if (productsData.length < pageSize) {
          // Son sayfa, 500'den az geldiğine göre başka veri kalmadı.
          hasMore = false;
        } else {
          // Sonraki sayfa için cursorları belirle
          final lastItem = productsData.last;
          cursorUpdatedAtStr = lastItem['updated_at']?.toString() ?? cursorUpdatedAtStr;
          cursorId = lastItem['id']?.toString();
        }

        // maxUpdatedAtStr'yi, gördüğümüz en büyük updated_at ile güncelle
        if (productsData.isNotEmpty) {
          final lastItem = productsData.last;
          final currentMax = lastItem['updated_at']?.toString();
          if (currentMax != null) {
            maxUpdatedAtStr = currentMax;
          }
        }
      }

      // Sadece ve sadece TÜM SAYFALAR BAŞARIYLA BİTİNCE last_successful_sync_at güncellenir.
      // Cihazın kendi saati (DateTime.now) YERİNE Supabase'den gelen gerçek veri saati kullanılır.
      if (maxUpdatedAtStr != null) {
        await _metadataDao.setLastSyncedAt(
          isletmeId: isletmeId,
          entity: SyncEntityType.products,
          syncedAt: DateTime.parse(maxUpdatedAtStr),
        );
      }

      developer.log(
        'Senkronizasyon başarıyla tamamlandı — Toplam $totalSynced ürün yerel DB\'ye kaydedildi.', 
        name: _logTag,
      );
    } catch (e, stackTrace) {
      // Hata durumunda last_successful_sync_at güncellenmez!
      developer.log(
        'Senkronizasyon sırasında hata oluştu — isletme_id=$isletmeId',
        name: _logTag,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Tam bir resync işlemi başlatır.
  /// Mevcut SQLite cache'ini temizler ve tüm ürünleri sıfırdan çeker.
  Future<void> fullResync(int isletmeId) async {
    developer.log('Full Resync başlatılıyor — isletme_id=$isletmeId', name: _logTag);
    try {
      await _productDao.deleteAllForIsletme(isletmeId);
      await _metadataDao.clearForIsletme(isletmeId);
      
      await syncProducts(isletmeId);
      
      developer.log('Full Resync başarıyla tamamlandı.', name: _logTag);
    } catch (e, stackTrace) {
      developer.log(
        'Full Resync hatası — isletme_id=$isletmeId',
        name: _logTag,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @visibleForTesting
  Future<List<Map<String, dynamic>>> fetchProductsPage(
    int isletmeId,
    String? cursorUpdatedAtStr,
    String? cursorId,
    int pageSize,
  ) async {
    var filterBuilder = _supabaseClient
        .from('products')
        .select()
        .eq('isletme_id', isletmeId);

    if (cursorUpdatedAtStr != null) {
      if (cursorId != null) {
        filterBuilder = filterBuilder.or(
          'updated_at.gt.$cursorUpdatedAtStr,and(updated_at.eq.$cursorUpdatedAtStr,id.gt.$cursorId)'
        );
      } else {
        filterBuilder = filterBuilder.gte('updated_at', cursorUpdatedAtStr);
      }
    }

    final response = await filterBuilder
        .order('updated_at', ascending: true)
        .order('id', ascending: true)
        .limit(pageSize);
    return List<Map<String, dynamic>>.from(response);
  }
}
