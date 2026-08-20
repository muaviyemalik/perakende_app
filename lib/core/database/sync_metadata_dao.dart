import 'dart:developer' as developer;

import 'package:sqflite/sqflite.dart';

import 'local_database.dart';

// =============================================================================
// SyncMetadataDao — sync_metadata tablosu erişim katmanı
// =============================================================================
//
// AMAÇ:
//   Her (isletme_id, entity_type) çifti için son başarılı senkronizasyon
//   zamanını saklar. SyncService bu bilgiyi incremental sync için kullanır
//   (ileride — mevcut scope dışında).
//
// KULLANIM:
//   final lastSync = await SyncMetadataDao.instance.getLastSyncedAt(
//     isletmeId: 42,
//     entity: SyncEntityType.products,
//   );
// =============================================================================

const _table = 'sync_metadata';
const _logTag = 'SYNC_METADATA_DAO';

/// Senkronizasyon yapılan varlık türleri.
enum SyncEntityType {
  products;

  String get value => name; // 'products'
}

class SyncMetadataDao {
  SyncMetadataDao._();

  static final SyncMetadataDao instance = SyncMetadataDao._();

  Future<Database> get _db => LocalDatabase.instance.database;

  // ---------------------------------------------------------------------------
  // YAZMA
  // ---------------------------------------------------------------------------

  /// Son senkronizasyon zamanını kaydeder veya günceller.
  ///
  /// Aynı (isletme_id, entity_type) çifti için her çağrı mevcut kaydın
  /// üzerine yazar (UNIQUE constraint + REPLACE).
  Future<void> setLastSyncedAt({
    required int isletmeId,
    required SyncEntityType entity,
    DateTime? syncedAt,
  }) async {
    final db = await _db;
    final now = (syncedAt ?? DateTime.now()).toUtc().toIso8601String();

    await db.insert(
      _table,
      {
        'isletme_id': isletmeId,
        'entity': entity.value,
        'last_successful_sync_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    developer.log(
      'setLastSyncedAt — isletme_id=$isletmeId, '
      'entity=${entity.value}, at=$now',
      name: _logTag,
    );
  }

  // ---------------------------------------------------------------------------
  // OKUMA
  // ---------------------------------------------------------------------------

  /// Son senkronizasyon zamanını döndürür.
  ///
  /// Kayıt yoksa `null` döner (hiç sync yapılmamış).
  Future<DateTime?> getLastSyncedAt({
    required int isletmeId,
    required SyncEntityType entity,
  }) async {
    final db = await _db;

    final rows = await db.query(
      _table,
      columns: ['last_successful_sync_at'],
      where: 'isletme_id = ? AND entity = ?',
      whereArgs: [isletmeId, entity.value],
      limit: 1,
    );

    if (rows.isEmpty || rows.first['last_successful_sync_at'] == null) {
      developer.log(
        'getLastSyncedAt — kayıt yok, isletme_id=$isletmeId, '
        'entity=${entity.value}',
        name: _logTag,
      );
      return null;
    }

    final raw = rows.first['last_successful_sync_at'] as String;
    final parsed = DateTime.tryParse(raw);

    developer.log(
      'getLastSyncedAt — isletme_id=$isletmeId, '
      'entity=${entity.value}, at=$raw',
      name: _logTag,
    );

    return parsed;
  }

  // ---------------------------------------------------------------------------
  // TEMİZLİK
  // ---------------------------------------------------------------------------

  /// Bir işletmenin tüm sync metadata kayıtlarını siler.
  /// Yalnızca hesap çıkışı veya tam sıfırlama senaryolarında kullanılır.
  Future<void> clearForIsletme(int isletmeId) async {
    final db = await _db;
    final count = await db.delete(
      _table,
      where: 'isletme_id = ?',
      whereArgs: [isletmeId],
    );

    developer.log(
      'clearForIsletme — isletme_id=$isletmeId, deleted=$count',
      name: _logTag,
    );
  }
}
