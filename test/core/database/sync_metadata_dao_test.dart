import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/sync_metadata_dao.dart';

import 'sqlite_test_helper.dart';

void main() {
  setUpAll(() {
    setupSqfliteTestHelper();
  });

  group('SyncMetadataDao Tests', () {
    late SyncMetadataDao dao;
    late Database db;

    setUp(() async {
      dao = SyncMetadataDao.instance;
      db = await LocalDatabase.instance.database;
      await db.delete('sync_metadata');
    });

    tearDownAll(() async {
      await LocalDatabase.instance.close();
    });

    test('getLastSyncedAt returns null if no sync has occurred', () async {
      final lastSync = await dao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      expect(lastSync, isNull);
    });

    test('setLastSyncedAt saves and getLastSyncedAt retrieves the correct time', () async {
      final syncTime = DateTime.parse('2024-01-01T10:00:00Z');
      await dao.setLastSyncedAt(
        isletmeId: 1,
        entity: SyncEntityType.products,
        syncedAt: syncTime,
      );

      final retrieved = await dao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      expect(retrieved, isNotNull);
      expect(retrieved!.isAtSameMomentAs(syncTime), isTrue);
    });

    test('Tenant isolation works in metadata', () async {
      final syncTime1 = DateTime.parse('2024-01-01T10:00:00Z');
      final syncTime2 = DateTime.parse('2024-01-02T10:00:00Z');
      
      await dao.setLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products, syncedAt: syncTime1);
      await dao.setLastSyncedAt(isletmeId: 2, entity: SyncEntityType.products, syncedAt: syncTime2);

      final retrieved1 = await dao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      final retrieved2 = await dao.getLastSyncedAt(isletmeId: 2, entity: SyncEntityType.products);

      expect(retrieved1!.isAtSameMomentAs(syncTime1), isTrue);
      expect(retrieved2!.isAtSameMomentAs(syncTime2), isTrue);
    });

    test('clearForIsletme removes only the specified tenant metadata', () async {
      final syncTime = DateTime.now();
      await dao.setLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products, syncedAt: syncTime);
      await dao.setLastSyncedAt(isletmeId: 2, entity: SyncEntityType.products, syncedAt: syncTime);

      await dao.clearForIsletme(1);

      final retrieved1 = await dao.getLastSyncedAt(isletmeId: 1, entity: SyncEntityType.products);
      final retrieved2 = await dao.getLastSyncedAt(isletmeId: 2, entity: SyncEntityType.products);

      expect(retrieved1, isNull);
      expect(retrieved2, isNotNull);
    });
  });
}
