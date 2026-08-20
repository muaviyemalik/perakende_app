import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/local_product_dao.dart';
import 'package:perakende_app/core/database/offline_mutation_dao.dart';

import 'sqlite_test_helper.dart';

void main() {
  const currentIsletmeId = 111;
  const otherIsletmeId = 222;

  setUpAll(() {
    setupSqfliteTestHelper();
  });

  setUp(() async {
    final dbPath = p.join(await getDatabasesPath(), 'perakende_local.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }

    final db = await LocalDatabase.instance.database;
    await db.delete('local_products');
    await db.delete('offline_product_mutations');
  });

  tearDownAll(() async {
    await LocalDatabase.instance.close();
    final dbPath = p.join(await getDatabasesPath(), 'perakende_local.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
  });

  test('Logout Cleanup Test - PENDING mutation varken logout yapıldığında tenant verileri silinir, diğeri korunur', () async {
    // 1. Current Tenant için veri ekle
    await LocalProductDao.instance.createLocal(
      isletmeId: currentIsletmeId,
      name: 'Current Tenant Urun',
      price: 10,
      stock: 5,
    );

    // 2. Diğer Tenant için veri ekle
    await LocalProductDao.instance.createLocal(
      isletmeId: otherIsletmeId,
      name: 'Other Tenant Urun',
      price: 20,
      stock: 10,
    );

    // Ön doğrulama
    var currentActive = await LocalProductDao.instance.getAllActive(currentIsletmeId);
    var otherActive = await LocalProductDao.instance.getAllActive(otherIsletmeId);
    expect(currentActive.length, 1);
    expect(otherActive.length, 1);

    var currentPending = await OfflineMutationDao.instance.getPendingMutations(currentIsletmeId);
    var otherPending = await OfflineMutationDao.instance.getPendingMutations(otherIsletmeId);
    expect(currentPending.length, 1);
    expect(otherPending.length, 1);

    // 3. LOGOUT (Temizlik) -> auth_provider.dart içindeki performLogout davranışı
    await LocalProductDao.instance.deleteAllForIsletme(currentIsletmeId);
    await OfflineMutationDao.instance.clearForIsletme(currentIsletmeId);

    // 4. Son Doğrulama
    currentActive = await LocalProductDao.instance.getAllActive(currentIsletmeId);
    otherActive = await LocalProductDao.instance.getAllActive(otherIsletmeId);
    currentPending = await OfflineMutationDao.instance.getPendingMutations(currentIsletmeId);
    otherPending = await OfflineMutationDao.instance.getPendingMutations(otherIsletmeId);

    // Current tenant'ın local verileri GİTTİ
    expect(currentActive, isEmpty);
    expect(currentPending, isEmpty);

    // Diğer tenant'ın local verileri KORUNDU
    expect(otherActive.length, 1);
    expect(otherPending.length, 1);
  });
}
