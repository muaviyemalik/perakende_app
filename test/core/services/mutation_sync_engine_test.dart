import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';

import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/local_product_dao.dart';
import 'package:perakende_app/core/database/offline_mutation_dao.dart';
import 'package:perakende_app/core/services/mutation_sync_engine.dart';
import 'package:perakende_app/core/utils/product_error_mapper.dart';

import '../database/sqlite_test_helper.dart';

void main() {
  const isletmeId = 999;
  late OfflineMutationDao mutationDao;
  late Database db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupSqfliteTestHelper();
  });

  setUp(() async {
    final dbPath = p.join(await getDatabasesPath(), 'perakende_local.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }

    db = await LocalDatabase.instance.database;
    await db.delete('local_products');
    await db.delete('offline_product_mutations');

    mutationDao = OfflineMutationDao.instance;
  });

  tearDownAll(() async {
    await LocalDatabase.instance.close();
    final dbPath = p.join(await getDatabasesPath(), 'perakende_local.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
  });

  test(
      'MutationSyncEngine - Başarılı işlem sonrası mutation SYNCED durumuna geçer',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun',
      price: 10,
      stock: 5,
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      return {'status': 'SUCCESS'};
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    final pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending, isEmpty);
  });

  test(
      'MutationSyncEngine - FIFO sırasına uyar, geçici hata durumunda retry count artar ve sıradaki işlemlere geçmez',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
    );
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 2',
      price: 20,
      stock: 10,
    );

    int rpcCallCount = 0;
    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      rpcCallCount++;
      throw const PostgrestException(message: 'timeout');
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    expect(rpcCallCount, 1);

    final pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending.length, 2);
    expect(pending[0]['retry_count'], 1);
    expect(pending[1]['retry_count'], 0);
  });

  test('MutationSyncEngine - 3 başarısız denemeden sonra DEAD_LETTER olur',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      throw const PostgrestException(message: 'timeout');
    }

    // 1. deneme
    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);
    var pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending[0]['retry_count'], 1);

    // 2. deneme
    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);
    pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending[0]['retry_count'], 2);

    // 3. deneme (Max sınır) -> DEAD_LETTER
    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending, isEmpty);

    final rows = await db.query('offline_product_mutations');
    expect(rows.length, 1);
    expect(rows.first['status'], 'DEAD_LETTER');
    expect(rows.first['last_error'], contains('Max retries exceeded'));
  });

  test(
      'MutationSyncEngine - Kalıcı hatalarda (CONFLICT vb) anında DEAD_LETTER olur',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      throw const PostgrestException(message: 'CONFLICT_DETECTED');
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    final pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending, isEmpty);

    final rows = await db.query('offline_product_mutations');
    expect(rows.first['status'], 'DEAD_LETTER');
    expect(rows.first['last_error'], contains('CONFLICT_DETECTED'));
  });

  test(
      'MutationSyncEngine - Kasiyer product mutation yetki hatası anında DEAD_LETTER olur',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Kasiyer Urunu',
      price: 10,
      stock: 5,
    );

    var rpcCallCount = 0;
    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      rpcCallCount++;
      throw const PostgrestException(message: 'PRODUCT_MUTATION_FORBIDDEN');
    }

    await MutationSyncEngine.instance.syncPendingMutations(
      isletmeId,
      rpcCaller: mockRpc,
    );

    expect(rpcCallCount, 1);
    expect(await mutationDao.getPendingMutations(isletmeId), isEmpty);

    final rows = await db.query('offline_product_mutations');
    expect(rows.single['status'], 'DEAD_LETTER');
    expect(rows.single['retry_count'], 0);
    expect(rows.single['last_error'], contains('PRODUCT_MUTATION_FORBIDDEN'));
  });

  test('MutationSyncEngine - Idempotency tekrarında SYNCED olarak işaretlenir',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      throw const PostgrestException(message: 'IDEMPOTENT_TEKRAR');
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    final pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending, isEmpty);

    final rows = await db.query('offline_product_mutations');
    expect(rows.first['status'], 'SYNCED');
  });

  test(
      'MutationSyncEngine - tenant barcode conflict becomes friendly DEAD_LETTER',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
      barcode: '12345',
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      throw const PostgrestException(
        message:
            'duplicate key value violates unique constraint "idx_products_unique_barcode"',
        code: '23505',
      );
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    expect(await mutationDao.getPendingMutations(isletmeId), isEmpty);
    final rows = await db.query('offline_product_mutations');
    expect(rows.single['status'], 'DEAD_LETTER');
    expect(rows.single['retry_count'], 0);
    expect(rows.single['last_error'], duplicateProductBarcodeMessage);
  });

  test('MutationSyncEngine - another unique violation remains retryable',
      () async {
    await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Urun 1',
      price: 10,
      stock: 5,
    );

    Future<dynamic> mockRpc(String fn, Map<String, dynamic> params) async {
      throw const PostgrestException(
        message:
            'duplicate key value violates unique constraint "another_unique_index"',
        code: '23505',
      );
    }

    await MutationSyncEngine.instance
        .syncPendingMutations(isletmeId, rpcCaller: mockRpc);

    final pending = await mutationDao.getPendingMutations(isletmeId);
    expect(pending.single['retry_count'], 1);
    expect(pending.single['last_error'], contains('another_unique_index'));
    expect(pending.single['last_error'], isNot(duplicateProductBarcodeMessage));
  });
}
