import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/local_product_dao.dart';
import 'package:perakende_app/core/database/offline_mutation_dao.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';

import 'sqlite_test_helper.dart';

void main() {
  const isletmeId = 999;

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
    final dbPath = p.join(await getDatabasesPath(), 'perakende_local.db');
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
  });

  test('Offline Mutations - Create, Update, Delete atomik çalışır ve kuyruğa eklenir', () async {
    // 1. Create Local
    final product = await LocalProductDao.instance.createLocal(
      isletmeId: isletmeId,
      name: 'Test Urun',
      price: 15.0,
      stock: 10,
    );

    expect(product.id, isNotNull);
    expect(product.name, 'Test Urun');
    
    var pending = await OfflineMutationDao.instance.getPendingMutations(isletmeId);
    expect(pending.length, 1);
    expect(pending.first['operation_type'], 'CREATE');
    expect(pending.first['product_id'], product.id);

    // 2. Update Local
    final updatedProduct = await LocalProductDao.instance.updateLocal(
      id: product.id,
      isletmeId: isletmeId,
      name: 'Test Urun Guncel',
      price: 20.0,
      stock: 5,
    );

    expect(updatedProduct.price, 20.0);
    
    pending = await OfflineMutationDao.instance.getPendingMutations(isletmeId);
    expect(pending.length, 2);
    expect(pending.last['operation_type'], 'UPDATE');
    expect(pending.last['product_id'], product.id);

    // 3. Delete Local
    await LocalProductDao.instance.softDeleteLocal(
      id: product.id,
      isletmeId: isletmeId,
    );

    pending = await OfflineMutationDao.instance.getPendingMutations(isletmeId);
    expect(pending.length, 3);
    expect(pending.last['operation_type'], 'DELETE');
    expect(pending.last['product_id'], product.id);

    // Aktif urun kalmamali
    final active = await LocalProductDao.instance.getAllActive(isletmeId);
    expect(active.isEmpty, isTrue);
  });

  test('Read-Sync Override Koruma - PENDING mutation varsa upsertBatch eski server verisini ezmez', () async {
    // 1. Ürün oluştur (Lokalde var, serverdan gelmiş gibi)
    final productId = const Uuid().v4();
    final now = DateTime.now();
    
    final serverProduct = LocalProduct(
      id: productId,
      isletmeId: isletmeId,
      name: 'Eski Isim',
      price: 10.0,
      stock: 5,
      createdAt: now,
      updatedAt: now,
    );
    
    await LocalProductDao.instance.upsertBatch(
      isletmeId: isletmeId, 
      products: [serverProduct],
    );

    // 2. Offline Update (Local mutation eklenecek, PENDING olacak)
    await LocalProductDao.instance.updateLocal(
      id: productId,
      isletmeId: isletmeId,
      name: 'Yeni Isim',
      price: 50.0,
      stock: 2,
    );

    var current = await LocalProductDao.instance.getById(id: productId, isletmeId: isletmeId);
    expect(current!.name, 'Yeni Isim');
    expect(current.price, 50.0);

    // 3. Geri dönük/Sync gecikmesi ile Server'dan eski veri gelirse (Read-Sync tetiklenirse)
    final serverOldProduct = LocalProduct(
      id: productId,
      isletmeId: isletmeId,
      name: 'Eski Isim',
      price: 10.0,
      stock: 5,
      createdAt: now,
      updatedAt: now.add(const Duration(seconds: 1)), // Server updated_at artmış olabilir
    );

    await LocalProductDao.instance.upsertBatch(
      isletmeId: isletmeId,
      products: [serverOldProduct],
    );

    // KORUMA: PENDING mutation olduğu için ezmemiş olmalı
    current = await LocalProductDao.instance.getById(id: productId, isletmeId: isletmeId);
    expect(current!.name, 'Yeni Isim', reason: 'PENDING mutation olan urunu server verisi ezip geçemez');
    expect(current.price, 50.0);

    // 4. Mutation SYNCED durumuna geçerse
    final pending = await OfflineMutationDao.instance.getPendingMutations(isletmeId);
    await OfflineMutationDao.instance.updateStatus(pending.last['id'], 'SYNCED');

    // 5. Server'dan yeni bir sync gelirse (artık PENDING değil)
    final serverNewProduct = LocalProduct(
      id: productId,
      isletmeId: isletmeId,
      name: 'En Yeni Isim',
      price: 100.0,
      stock: 10,
      createdAt: now,
      updatedAt: now.add(const Duration(seconds: 2)),
    );

    await LocalProductDao.instance.upsertBatch(
      isletmeId: isletmeId,
      products: [serverNewProduct],
    );

    // ARTIK EZMELİ: Çünkü PENDING mutation kalmadı.
    current = await LocalProductDao.instance.getById(id: productId, isletmeId: isletmeId);
    expect(current!.name, 'En Yeni Isim', reason: 'SYNCED olduğu için yeni gelen veri yazılmalı');
    expect(current.price, 100.0);
  });

  test('Transaction Rollback - Hata durumunda local_products ve offline_product_mutations birlikte geri alınır', () async {
    final db = await LocalDatabase.instance.database;
    final productId = const Uuid().v4();
    final now = DateTime.now();

    final activeBefore = await LocalProductDao.instance.getAllActive(isletmeId);
    final pendingBefore = await OfflineMutationDao.instance.getPendingMutations(isletmeId);

    try {
      await db.transaction((txn) async {
        // 1. local_products tablosuna geçerli bir kayıt ekle
        await txn.insert('local_products', {
          'id': productId,
          'isletme_id': isletmeId,
          'name': 'Rollback Test Urunu',
          'price': 100.0,
          'stock': 10,
          'updated_at': now.toIso8601String(),
        });

        // 2. offline_product_mutations tablosuna GEÇERSİZ bir kayıt eklemeye çalış (HATA FIRLATACAK)
        // NOT NULL constraint olan created_at vb. alanları eksik göndererek SQLite hatası tetikliyoruz.
        await txn.insert('offline_product_mutations', {
          'idempotency_key': const Uuid().v4(),
          'isletme_id': isletmeId,
          // 'operation_type': 'CREATE', // Eksik alan, hata fırlatacak
          'product_id': productId,
        });
      });
      fail('Exception fırlatılmalıydı');
    } catch (e) {
      // Beklenen hata (DatabaseException: NOT NULL constraint failed)
    }

    // Doğrulama: Transaction rollback olduğu için ilk insert de geri alınmış olmalı.
    final activeAfter = await LocalProductDao.instance.getAllActive(isletmeId);
    final pendingAfter = await OfflineMutationDao.instance.getPendingMutations(isletmeId);

    expect(activeAfter.length, activeBefore.length, reason: 'local_products geri alınmalı');
    expect(pendingAfter.length, pendingBefore.length, reason: 'offline_product_mutations değişmemeli');
    
    final insertedProduct = await LocalProductDao.instance.getById(id: productId, isletmeId: isletmeId);
    expect(insertedProduct, isNull, reason: 'Ürün veritabanında kesinlikle bulunmamalı');
  });
}
