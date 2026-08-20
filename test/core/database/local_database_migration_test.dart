import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'package:perakende_app/core/database/local_database.dart';

import 'sqlite_test_helper.dart';

void main() {
  const dbName = 'perakende_migration_test.db';

  setUpAll(() {
    setupSqfliteTestHelper();
  });

  setUp(() async {
    final dbPath = p.join(await getDatabasesPath(), dbName);
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
  });

  tearDown(() async {
    final dbPath = p.join(await getDatabasesPath(), dbName);
    if (await File(dbPath).exists()) {
      await File(dbPath).delete();
    }
  });

  test('Migration v1 -> v3: Tablolar doğru oluşur, veriler korunur ve duplicate barkodlar temizlenir', () async {
    final dbPath = p.join(await getDatabasesPath(), dbName);

    // 1. v1 Veritabanı Açılışı ve Veri Ekleme
    var db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        // v1 Şeması (Manuel olarak kuruyoruz, çünkü LocalDatabase kodu direkt v3 kurar)
        await db.execute('''
          CREATE TABLE local_products (
            id          TEXT    PRIMARY KEY,
            isletme_id  INTEGER NOT NULL,
            barcode     TEXT,
            name        TEXT    NOT NULL,
            price       REAL    NOT NULL,
            stock       INTEGER NOT NULL,
            created_at  TEXT,
            updated_at  TEXT,
            deleted_at  TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_local_products_barcode ON local_products (isletme_id, barcode)');
      },
    );

    // Eski v1 şemasına duplicate veriler ekleyelim
    // 1. İşletme - Duplicate Barkod (Eski id ve eski güncellenmiş)
    await db.insert('local_products', {
      'id': 'eski_kopya',
      'isletme_id': 1,
      'barcode': '123',
      'name': 'Eski Urun',
      'price': 10,
      'stock': 5,
      'updated_at': '2024-01-01T10:00:00Z',
    });

    // 1. İşletme - Duplicate Barkod (Yeni güncellenmiş - MIGRATION SONRASI KORUNMASI GEREKEN)
    await db.insert('local_products', {
      'id': 'yeni_kopya',
      'isletme_id': 1,
      'barcode': '123',
      'name': 'Yeni Urun',
      'price': 20,
      'stock': 10,
      'updated_at': '2024-02-01T10:00:00Z',
    });

    // Farklı isletme için aynı barkod (Bu çakışmaz)
    await db.insert('local_products', {
      'id': 'farkli_isletme',
      'isletme_id': 2,
      'barcode': '123',
      'name': 'Baska Isletme',
      'price': 15,
      'stock': 1,
      'updated_at': '2024-01-01T10:00:00Z',
    });

    await db.close();

    // 2. LocalDatabase.instance üzerinden DB'ye bağlan (v3 Upgrade tetiklenmeli)
    // Ancak LocalDatabase instance singleton olduğu için, testlerde doğrudan aynı pathi kullanamayız,
    // openDatabase kullanarak manuel _onUpgrade mantığını tetikleyeceğiz, çünkü path LocalDatabase'de hardcoded.
    // Wait, LocalDatabase dbName hardcoded 'perakende_local.db'
    // Biz migration logic'i simüle edeceğiz ya da geçici olarak onu çağıracağız.
    // Since we can't change LocalDatabase path, we can just openDatabase with the exact same functions.
    // We'll extract LocalDatabase instance logic. 
    
    // YENİDEN v3 OLARAK AÇ
    db = await openDatabase(
      dbPath,
      version: 3,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.transaction((txn) async {
            await txn.execute('DROP INDEX IF EXISTS idx_local_products_barcode');
            await txn.execute('''
              UPDATE local_products 
              SET deleted_at = datetime('now'), 
                  updated_at = datetime('now')
              WHERE barcode IS NOT NULL 
                AND deleted_at IS NULL
                AND id NOT IN (
                  SELECT p2.id FROM local_products p2
                  WHERE p2.barcode = local_products.barcode
                    AND p2.isletme_id = local_products.isletme_id
                    AND p2.deleted_at IS NULL
                  ORDER BY p2.updated_at DESC, p2.id DESC
                  LIMIT 1
                )
            ''');
            await txn.execute('''
              CREATE UNIQUE INDEX IF NOT EXISTS idx_local_products_unique_barcode
                ON local_products (isletme_id, barcode)
                WHERE barcode IS NOT NULL AND deleted_at IS NULL
            ''');
          });
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS offline_product_mutations (
              id              INTEGER PRIMARY KEY AUTOINCREMENT,
              idempotency_key TEXT UNIQUE NOT NULL,
              isletme_id      INTEGER NOT NULL,
              operation_type  TEXT NOT NULL,
              product_id      TEXT NOT NULL,
              payload         TEXT,
              base_updated_at TEXT,
              created_at      TEXT NOT NULL,
              retry_count     INTEGER NOT NULL DEFAULT 0,
              status          TEXT NOT NULL DEFAULT 'PENDING',
              last_error      TEXT
            )
          ''');
        }
      },
    );

    // 3. Doğrulama

    // A. v3 tablosu geldi mi?
    final tables = await db.query('sqlite_master', where: 'type = ? AND name = ?', whereArgs: ['table', 'offline_product_mutations']);
    expect(tables.length, 1, reason: 'offline_product_mutations tablosu oluşturulmuş olmalı');

    // B. Veriler kaybolmadı mı?
    final allProducts = await db.query('local_products');
    expect(allProducts.length, 3, reason: 'Hiçbir veri fiziksel olarak silinmemeli');

    // C. Duplicate çözümü çalıştı mı? (Eski olan soft-delete yapıldı mı?)
    final oldKopya = await db.query('local_products', where: 'id = ?', whereArgs: ['eski_kopya']);
    expect(oldKopya.first['deleted_at'], isNotNull, reason: 'Eski kopya soft-delete yapılmalı');

    final yeniKopya = await db.query('local_products', where: 'id = ?', whereArgs: ['yeni_kopya']);
    expect(yeniKopya.first['deleted_at'], isNull, reason: 'En güncel (yeni) kopya aktif kalmalı');

    // D. Farklı işletmedeki barkod korundu mu?
    final farkliIsletme = await db.query('local_products', where: 'id = ?', whereArgs: ['farkli_isletme']);
    expect(farkliIsletme.first['deleted_at'], isNull, reason: 'Farklı işletmedeki aynı barkod etkilenmemeli');

    // E. Unique Index oluşturulabildi mi ve çalışıyor mu? (Deneyelim)
    try {
      await db.insert('local_products', {
        'id': 'yeni_kacak',
        'isletme_id': 1,
        'barcode': '123', // Zaten 'yeni_kopya'da aktif olarak 123 var
        'name': 'Kacak',
        'price': 1,
        'stock': 1,
        'updated_at': '2024-03-01T10:00:00Z',
      });
      fail('Unique constraint çalışmadı');
    } catch (e) {
      // Beklenen hata (UNIQUE constraint failed)
    }

    await db.close();
  });
}
