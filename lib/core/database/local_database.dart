import 'dart:developer' as developer;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// =============================================================================
// LocalDatabase — SQLite veritabanı yöneticisi (singleton)
// =============================================================================
//
// AMAÇ:
//   Çevrimdışı ürün cache'ini SQLite üzerinde saklar.
//   OfflineSaleQueue (SharedPreferences) ile çakışmaz — tamamen ayrı sorumluluk.
//
// TABLOLAR:
//   - local_products : Ürün cache'i (isletme_id bazlı, soft-delete destekli)
//   - sync_metadata  : Her isletme için son senkronizasyon zamanı
//
// GÜVENLİK:
//   isletme_id her zaman auth oturumundan gelen değerle DAO'ya iletilir.
//   LocalDatabase bu değeri asla türetmez veya saklamaz.
// =============================================================================

const _dbName = 'perakende_local.db';
const _dbVersion = 3;
const _logTag = 'LOCAL_DB';

/// SQLite bağlantısını döndüren singleton.
///
/// İlk erişimde `_initDb()` çalışır; sonraki çağrılar aynı [Database]
/// örneğini döndürür.
class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;

  /// Açık veritabanı bağlantısını döndürür. İlk çağrıda başlatır.
  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  // ---------------------------------------------------------------------------
  // Başlatma
  // ---------------------------------------------------------------------------

  Future<Database> _initDb() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(appDir.path, _dbName);

    developer.log(
      'SQLite açılıyor — path=$dbPath, version=$_dbVersion',
      name: _logTag,
    );

    return openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onOpen: (db) => developer.log(
        'SQLite bağlantısı açıldı — path=$dbPath',
        name: _logTag,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Şema
  // ---------------------------------------------------------------------------

  Future<void> _onCreate(Database db, int version) async {
    developer.log(
      'SQLite şeması oluşturuluyor — version=$version',
      name: _logTag,
    );

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

    // isletme_id bazlı taramayı hızlandıran index
    await db.execute('''
      CREATE INDEX idx_local_products_isletme
        ON local_products (isletme_id)
    ''');

    // Barkod aramasını hızlandıran bileşik index
    await db.execute('''
      CREATE INDEX idx_local_products_barcode
        ON local_products (isletme_id, barcode)
    ''');

    // Tarih/sıralama bazlı sorguları hızlandıran index
    await db.execute('''
      CREATE INDEX idx_local_products_updated_at
        ON local_products (isletme_id, updated_at)
    ''');

    // Barkod için unique constraint (null değerler hariç) - v2
    await db.execute('''
      CREATE UNIQUE INDEX idx_local_products_unique_barcode
        ON local_products (isletme_id, barcode)
        WHERE barcode IS NOT NULL AND deleted_at IS NULL
    ''');

    await db.execute('''
      CREATE TABLE sync_metadata (
        isletme_id                INTEGER NOT NULL,
        entity                    TEXT    NOT NULL,
        last_successful_sync_at   TEXT,
        PRIMARY KEY (isletme_id, entity)
      )
    ''');

    await db.execute('''
      CREATE TABLE offline_product_mutations (
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

    await db.execute('''
      CREATE INDEX idx_offline_mutations_tenant
        ON offline_product_mutations (isletme_id, status, id)
    ''');

    developer.log('SQLite şeması oluşturuldu', name: _logTag);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    developer.log(
      'SQLite şeması güncelleniyor — old=$oldVersion, new=$newVersion',
      name: _logTag,
    );

    if (oldVersion < 2) {
      developer.log('Migration v1 -> v2: Unique barkod index ekleniyor.', name: _logTag);
      
      // Transaction içinde güvenli şekilde kopyaları temizle ve index oluştur.
      await db.transaction((txn) async {
        // Eski non-unique indexi düşür
        await txn.execute('DROP INDEX IF EXISTS idx_local_products_barcode');

        // 1. Deduplication (Soft-Delete)
        // Aynı işletmede aynı barkoda sahip birden fazla aktif kayıt varsa,
        // updated_at veya id'si en büyük olanı (winner) hariç diğerlerini soft-delete yap.
        // SQLite'da ROW_NUMBER() over PARTITION olmadığı eski sürümleri de desteklemek için
        // correlated subquery kullanıyoruz.
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

        // 2. Kısmi Unique Index oluştur
        await txn.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS idx_local_products_unique_barcode
            ON local_products (isletme_id, barcode)
            WHERE barcode IS NOT NULL AND deleted_at IS NULL
        ''');
      });
    }
    if (oldVersion < 3) {
      developer.log('Migration v2 -> v3: offline_product_mutations tablosu ekleniyor.', name: _logTag);
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
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_offline_mutations_tenant
          ON offline_product_mutations (isletme_id, status, id)
      ''');
    }
  }

  // ---------------------------------------------------------------------------
  // Yardımcı — test / temizlik
  // ---------------------------------------------------------------------------

  /// Veritabanı bağlantısını kapatır. Yalnızca test / teardown için.
  Future<void> close() async {
    await _db?.close();
    _db = null;
    developer.log('SQLite bağlantısı kapatıldı', name: _logTag);
  }
}
