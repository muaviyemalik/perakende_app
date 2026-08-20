import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/local_product_dao.dart';
import 'package:perakende_app/core/database/sync_metadata_dao.dart';
import 'package:perakende_app/core/services/product_sync_service.dart';

import '../database/sqlite_test_helper.dart';

class TestProductSyncService extends ProductSyncService {
  TestProductSyncService({
    super.supabaseClient,
    super.productDao,
    super.metadataDao,
  });

  List<Map<String, dynamic>> dataToReturn = [];
  bool shouldThrow = false;
  
  // Track how many times fetchProductsPage was called to simulate pagination
  int callCount = 0;
  List<List<Map<String, dynamic>>> pages = [];

  @override
  Future<List<Map<String, dynamic>>> fetchProductsPage(
    int isletmeId,
    String? cursorUpdatedAtStr,
    String? cursorId,
    int pageSize,
  ) async {
    if (shouldThrow) {
      throw Exception('Sync error');
    }

    List<Map<String, dynamic>> currentData = [];
    if (pages.isNotEmpty) {
      if (callCount < pages.length) {
        currentData = pages[callCount];
      }
    } else {
      currentData = dataToReturn;
    }
    callCount++;
    return currentData;
  }
}

class DummySupabaseClient extends Fake implements SupabaseClient {}

void main() {
  setUpAll(() {
    setupSqfliteTestHelper();
  });

  group('ProductSyncService Tests', () {
    late LocalProductDao productDao;
    late SyncMetadataDao metadataDao;
    late Database db;
    late TestProductSyncService syncService;

    setUp(() async {
      productDao = LocalProductDao.instance;
      metadataDao = SyncMetadataDao.instance;
      db = await LocalDatabase.instance.database;
      await db.delete('local_products');
      await db.delete('sync_metadata');
      
      syncService = TestProductSyncService(
        supabaseClient: DummySupabaseClient(),
        productDao: productDao,
        metadataDao: metadataDao,
      );
    });

    tearDownAll(() async {
      await LocalDatabase.instance.close();
    });

    test('First sync fetches all products and advances metadata to max updated_at', () async {
      syncService.dataToReturn = [
        {
          'id': '1',
          'isletme_id': 1,
          'barcode': '111',
          'name': 'Ürün 1',
          'price': 10,
          'stock': 5,
          'updated_at': '2024-01-01T10:00:00Z',
        },
        {
          'id': '2',
          'isletme_id': 1,
          'barcode': '222',
          'name': 'Ürün 2',
          'price': 20,
          'stock': 10,
          'updated_at': '2024-01-01T11:00:00Z', // Max updated_at
        },
      ];

      await syncService.syncProducts(1);

      // Check DB
      final active = await productDao.getAllActive(1);
      expect(active.length, 2);
      
      // Check Metadata
      final lastSync = await metadataDao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      expect(lastSync, isNotNull);
      expect(lastSync!.toUtc().toIso8601String(), '2024-01-01T11:00:00.000Z');
    });

    test('Pagination processes all pages and saves max updated_at', () async {
      // Create 500 items for page 1
      final page1 = List.generate(500, (i) => {
        'id': 'p$i',
        'isletme_id': 1,
        'name': 'U$i',
        'price': 10,
        'stock': 5,
        'updated_at': '2024-01-01T10:00:00Z',
      });
      
      // Create 10 items for page 2
      final page2 = List.generate(10, (i) => {
        'id': 'p2_$i',
        'isletme_id': 1,
        'name': 'U2_$i',
        'price': 10,
        'stock': 5,
        'updated_at': '2024-01-01T12:00:00Z',
      });

      syncService.pages = [page1, page2];

      await syncService.syncProducts(1);

      final active = await productDao.getAllActive(1);
      expect(active.length, 510);
      
      final lastSync = await metadataDao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      expect(lastSync, isNotNull);
      expect(lastSync!.toUtc().toIso8601String(), '2024-01-01T12:00:00.000Z');
    });

    test('Sync failure does NOT advance metadata', () async {
      // First successful sync
      syncService.dataToReturn = [
        {
          'id': '1',
          'isletme_id': 1,
          'name': 'Ürün 1',
          'price': 10,
          'stock': 5,
          'updated_at': '2024-01-01T10:00:00Z',
        },
      ];
      await syncService.syncProducts(1);
      final initialSync = await metadataDao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);

      // Now set client to throw
      syncService.shouldThrow = true;
      syncService.pages = [];
      
      try {
        await syncService.syncProducts(1);
        fail('Should have thrown');
      } catch (e) {
        // Expected
      }

      // Metadata should not have advanced
      final afterFailSync = await metadataDao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      expect(initialSync!.isAtSameMomentAs(afterFailSync!), isTrue);
    });

    test('Soft deleted products from Supabase are updated locally and filtered out', () async {
      // 1. Ürünü normal ekle
      syncService.dataToReturn = [
        {
          'id': '1',
          'isletme_id': 1,
          'name': 'Ürün 1',
          'price': 10,
          'stock': 5,
          'updated_at': '2024-01-01T10:00:00Z',
          'deleted_at': null,
        },
      ];
      await syncService.syncProducts(1);
      
      var active = await productDao.getAllActive(1);
      expect(active.length, 1);

      // 2. Ürünün silindiğini simüle et (incremental sync ile gelecek)
      syncService.dataToReturn = [
        {
          'id': '1',
          'isletme_id': 1,
          'name': 'Ürün 1',
          'price': 10,
          'stock': 5,
          'updated_at': '2024-01-02T10:00:00Z',
          'deleted_at': '2024-01-02T10:00:00Z',
        },
      ];
      await syncService.syncProducts(1);
      
      // DB'de soft delete olarak işaretlendi mi?
      active = await productDao.getAllActive(1);
      expect(active.isEmpty, true);
    });
  });
}
