import 'dart:convert';
import 'dart:developer' as developer;
import 'package:uuid/uuid.dart';

import 'package:sqflite/sqflite.dart';

import 'local_database.dart';

// =============================================================================
// LocalProductDao — local_products tablosu erişim katmanı
// =============================================================================
//
// GÜVENLİK:
//   Her public metot zorunlu `isletmeId` parametresi alır.
//   Hiçbir sorgu isletme_id filtresi olmadan çalışmaz.
//   isletme_id değeri asla bu sınıf içinde türetilmez veya saklanmaz;
//   çağıran katman auth oturumundan geçirir.
//
// SOFT DELETE:
//   Silinen ürünler fiziksel olarak kaldırılmaz; deleted_at alanı dolar.
//   Aktif ürün sorgularında WHERE deleted_at IS NULL koşulu uygulanır.
//
// UPSERT:
//   upsertBatch() tek bir transaction içinde çalışır —
//   kısmen yazma (partial write) olmaz.
// =============================================================================

const _table = 'local_products';
const _logTag = 'LOCAL_PRODUCT_DAO';

/// Tek bir ürünü temsil eden değer nesnesi.
///
/// [deletedAt] null ise ürün aktiftir; dolu ise soft-delete edilmiştir.
class LocalProduct {
  const LocalProduct({
    required this.id,
    required this.isletmeId,
    this.barcode,
    required this.name,
    required this.price,
    required this.stock,
    this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final int isletmeId;
  final String? barcode;
  final String name;
  final double price;
  final int stock;
  final DateTime? createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  // ---------------------------------------------------------------------------
  // Serileştirme
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toMap() => {
        'id': id,
        'isletme_id': isletmeId,
        'barcode': barcode,
        'name': name,
        'price': price,
        'stock': stock,
        'created_at': createdAt?.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'deleted_at': deletedAt?.toIso8601String(),
      };

  factory LocalProduct.fromMap(Map<String, dynamic> map) {
    return LocalProduct(
      id: map['id'] as String,
      isletmeId: map['isletme_id'] as int,
      barcode: map['barcode'] as String?,
      name: map['name'] as String,
      price: (map['price'] as num).toDouble(),
      stock: map['stock'] as int,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: map['deleted_at'] != null
          ? DateTime.tryParse(map['deleted_at'] as String)
          : null,
    );
  }

  /// Supabase/API satırından [LocalProduct] oluşturur.
  ///
  /// API satırında `updated_at` yoksa [DateTime.now()] kullanılır.
  factory LocalProduct.fromApiMap(Map<String, dynamic> map) {
    return LocalProduct(
      id: map['id'] as String,
      isletmeId: map['isletme_id'] as int,
      barcode: map['barcode'] as String?,
      name: map['name'] as String,
      price: (map['price'] as num).toDouble(),
      stock: map['stock'] as int,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      deletedAt: map['deleted_at'] != null
          ? DateTime.tryParse(map['deleted_at'] as String)
          : null,
    );
  }

  /// Sadece UI / provider katmanının beklediği `Map<String, dynamic>` formatı.
  Map<String, dynamic> toProviderMap() => {
        'id': id,
        'isletme_id': isletmeId,
        'barcode': barcode,
        'name': name,
        'price': price,
        'stock': stock,
      };
}

// =============================================================================
// DAO
// =============================================================================

class LocalProductDao {
  LocalProductDao._();

  static final LocalProductDao instance = LocalProductDao._();

  Future<Database> get _db => LocalDatabase.instance.database;

  // ---------------------------------------------------------------------------
  // YAZMA
  // ---------------------------------------------------------------------------

  /// [products] listesini tek bir transaction içinde upsert eder.
  ///
  /// Mevcut kayıtlar güncellenir (REPLACE), yeni olanlar eklenir.
  /// İşlem atomiktir — tüm liste yazılır ya da hiçbiri yazılmaz.
  Future<void> upsertBatch({
    required int isletmeId,
    required List<LocalProduct> products,
  }) async {
    if (products.isEmpty) return;

    // Güvenlik: tüm satırların isletme_id'si çağıranın isletme_id'siyle eşleşmeli
    for (final p in products) {
      assert(
        p.isletmeId == isletmeId,
        'upsertBatch: isletme_id uyuşmazlığı — beklenen=$isletmeId, gelen=${p.isletmeId}',
      );
    }

    final db = await _db;

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final product in products) {
        batch.rawInsert('''
          INSERT INTO $_table (id, isletme_id, barcode, name, price, stock, created_at, updated_at, deleted_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            barcode = excluded.barcode,
            name = excluded.name,
            price = excluded.price,
            stock = excluded.stock,
            updated_at = excluded.updated_at,
            deleted_at = excluded.deleted_at
          WHERE NOT EXISTS (
            SELECT 1 FROM offline_product_mutations
            WHERE product_id = excluded.id AND status = 'PENDING'
          )
        ''', [
          product.id,
          product.isletmeId,
          product.barcode,
          product.name,
          product.price,
          product.stock,
          product.createdAt?.toIso8601String(),
          product.updatedAt.toIso8601String(),
          product.deletedAt?.toIso8601String(),
        ]);
      }
      await batch.commit(noResult: true);
    });

    developer.log(
      'upsertBatch tamamlandı — isletme_id=$isletmeId, count=${products.length}',
      name: _logTag,
    );
  }

  /// Yeni ürün oluşturur ve mutasyon kuyruğuna ekler (Atomik).
  Future<LocalProduct> createLocal({
    required int isletmeId,
    required String name,
    required double price,
    required int stock,
    String? barcode,
  }) async {
    final db = await _db;
    final String productId = const Uuid().v4();
    final String idempotencyKey = const Uuid().v4();
    final now = DateTime.now();
    
    final product = LocalProduct(
      id: productId,
      isletmeId: isletmeId,
      barcode: barcode,
      name: name,
      price: price,
      stock: stock,
      createdAt: now,
      updatedAt: now,
    );

    final payload = jsonEncode({
      'name': name,
      'price': price,
      'stock': stock,
      if (barcode != null) 'barcode': barcode,
    });

    await db.transaction((txn) async {
      await txn.insert(_table, product.toMap());

      await txn.insert('offline_product_mutations', {
        'idempotency_key': idempotencyKey,
        'isletme_id': isletmeId,
        'operation_type': 'CREATE',
        'product_id': productId,
        'payload': payload,
        'base_updated_at': null,
        'created_at': now.toIso8601String(),
        'retry_count': 0,
        'status': 'PENDING',
      });
    });

    developer.log('createLocal tamamlandı — id=$productId', name: _logTag);
    return product;
  }

  /// Ürünü günceller ve mutasyon kuyruğuna ekler (Atomik).
  Future<LocalProduct> updateLocal({
    required String id,
    required int isletmeId,
    required String name,
    required double price,
    required int stock,
    String? barcode,
  }) async {
    final db = await _db;
    final String idempotencyKey = const Uuid().v4();
    final now = DateTime.now();

    // Mevcut ürünü bul (base_updated_at için)
    final existing = await getById(id: id, isletmeId: isletmeId);
    if (existing == null) {
      throw Exception('Ürün bulunamadı');
    }

    final product = LocalProduct(
      id: id,
      isletmeId: isletmeId,
      barcode: barcode,
      name: name,
      price: price,
      stock: stock,
      createdAt: existing.createdAt,
      updatedAt: now, // Yeni local updated_at
    );

    final payload = jsonEncode({
      'name': name,
      'price': price,
      'stock': stock,
      'barcode': barcode,
    });

    await db.transaction((txn) async {
      await txn.update(
        _table,
        product.toMap(),
        where: 'id = ? AND isletme_id = ?',
        whereArgs: [id, isletmeId],
      );

      await txn.insert('offline_product_mutations', {
        'idempotency_key': idempotencyKey,
        'isletme_id': isletmeId,
        'operation_type': 'UPDATE',
        'product_id': id,
        'payload': payload,
        'base_updated_at': existing.updatedAt.toIso8601String(),
        'created_at': now.toIso8601String(),
        'retry_count': 0,
        'status': 'PENDING',
      });
    });

    developer.log('updateLocal tamamlandı — id=$id', name: _logTag);
    return product;
  }

  /// Ürünü soft-delete yapar ve mutasyon kuyruğuna ekler (Atomik).
  Future<void> softDeleteLocal({
    required String id,
    required int isletmeId,
  }) async {
    final db = await _db;
    final String idempotencyKey = const Uuid().v4();
    final now = DateTime.now();

    final existing = await getById(id: id, isletmeId: isletmeId);
    if (existing == null) return;

    await db.transaction((txn) async {
      await txn.update(
        _table,
        {'deleted_at': now.toIso8601String()},
        where: 'id = ? AND isletme_id = ?',
        whereArgs: [id, isletmeId],
      );

      await txn.insert('offline_product_mutations', {
        'idempotency_key': idempotencyKey,
        'isletme_id': isletmeId,
        'operation_type': 'DELETE',
        'product_id': id,
        'payload': null,
        'base_updated_at': existing.updatedAt.toIso8601String(),
        'created_at': now.toIso8601String(),
        'retry_count': 0,
        'status': 'PENDING',
      });
    });

    developer.log('softDeleteLocal tamamlandı — id=$id', name: _logTag);
  }

  /// Tek bir ürünü soft-delete eder (deleted_at doldurulur). SADECE SYNC İÇİN.
  Future<void> softDelete({
    required String id,
    required int isletmeId,
  }) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();

    final affected = await db.update(
      _table,
      {'deleted_at': now},
      where: 'id = ? AND isletme_id = ?',
      whereArgs: [id, isletmeId],
    );

    developer.log(
      'softDelete — id=$id, isletme_id=$isletmeId, affected=$affected',
      name: _logTag,
    );
  }

  /// İşletmeye ait tüm ürünleri fiziksel olarak siler.
  /// Yalnızca tam resync öncesinde kullanılır.
  Future<void> deleteAllForIsletme(int isletmeId) async {
    final db = await _db;
    final count = await db.delete(
      _table,
      where: 'isletme_id = ?',
      whereArgs: [isletmeId],
    );

    developer.log(
      'deleteAllForIsletme — isletme_id=$isletmeId, deleted=$count',
      name: _logTag,
    );
  }

  // ---------------------------------------------------------------------------
  // OKUMA
  // ---------------------------------------------------------------------------

  /// İşletmeye ait aktif ürünlerin tamamını döndürür (silinmemişler).
  ///
  /// Sonuçlar [name] alanına göre artan sırada döner.
  Future<List<LocalProduct>> getAllActive(int isletmeId) async {
    final db = await _db;

    final rows = await db.query(
      _table,
      where: 'isletme_id = ? AND deleted_at IS NULL',
      whereArgs: [isletmeId],
      orderBy: 'name ASC',
    );

    developer.log(
      'getAllActive — isletme_id=$isletmeId, count=${rows.length}',
      name: _logTag,
    );

    return rows.map(LocalProduct.fromMap).toList();
  }

  /// Barkod ile aktif ürün arar. Bulunamazsa `null` döner.
  ///
  /// GÜVENLİK: isletme_id filtresi uygulanır — başka işletmenin barkodu sonuç vermez.
  Future<LocalProduct?> getByBarcode({
    required String barcode,
    required int isletmeId,
  }) async {
    final db = await _db;

    final rows = await db.query(
      _table,
      where: 'barcode = ? AND isletme_id = ? AND deleted_at IS NULL',
      whereArgs: [barcode, isletmeId],
      limit: 1,
    );

    if (rows.isEmpty) {
      developer.log(
        'getByBarcode — bulunamadı, barcode=$barcode, isletme_id=$isletmeId',
        name: _logTag,
      );
      return null;
    }

    final product = LocalProduct.fromMap(rows.first);
    developer.log(
      'getByBarcode — bulundu, id=${product.id}, isletme_id=$isletmeId',
      name: _logTag,
    );
    return product;
  }

  /// ID ile aktif ürün arar. Bulunamazsa `null` döner.
  Future<LocalProduct?> getById({
    required String id,
    required int isletmeId,
  }) async {
    final db = await _db;

    final rows = await db.query(
      _table,
      where: 'id = ? AND isletme_id = ? AND deleted_at IS NULL',
      whereArgs: [id, isletmeId],
      limit: 1,
    );

    return rows.isEmpty ? null : LocalProduct.fromMap(rows.first);
  }

  /// İşletmeye ait aktif ürün sayısını döndürür.
  Future<int> countActive(int isletmeId) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $_table WHERE isletme_id = ? AND deleted_at IS NULL',
      [isletmeId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}
