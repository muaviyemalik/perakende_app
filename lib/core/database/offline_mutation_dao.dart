import 'package:sqflite/sqflite.dart';
import 'local_database.dart';

class OfflineMutationDao {
  OfflineMutationDao._();
  static final OfflineMutationDao instance = OfflineMutationDao._();

  static const String tableName = 'offline_product_mutations';

  Future<Database> get _db async => LocalDatabase.instance.database;

  Future<void> clearForIsletme(int isletmeId) async {
    final db = await _db;
    await db.delete(
      tableName,
      where: 'isletme_id = ?',
      whereArgs: [isletmeId],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingMutations(int isletmeId) async {
    final db = await _db;
    return await db.query(
      tableName,
      where: 'isletme_id = ? AND status = ?',
      whereArgs: [isletmeId, 'PENDING'],
      orderBy: 'id ASC',
    );
  }

  Future<void> updateStatus(
      int id, String status, {String? lastError, int? retryCount}) async {
    final db = await _db;
    final Map<String, dynamic> data = {'status': status};
    if (lastError != null) data['last_error'] = lastError;
    if (retryCount != null) data['retry_count'] = retryCount;

    await db.update(
      tableName,
      data,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
