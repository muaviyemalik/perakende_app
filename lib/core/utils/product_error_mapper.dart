import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const duplicateProductBarcodeMessage =
    'Bu barkod bu işletmede başka bir üründe zaten kullanılıyor.';

class DuplicateProductBarcodeException implements Exception {
  const DuplicateProductBarcodeException();

  @override
  String toString() => duplicateProductBarcodeMessage;
}

bool isTenantBarcodeUniqueViolation(PostgrestException error) {
  if (error.code != '23505') return false;

  const indexName = 'idx_products_unique_barcode';
  return error.message.contains(indexName) ||
      (error.details?.toString().contains(indexName) ?? false) ||
      (error.hint?.contains(indexName) ?? false);
}

bool isLocalTenantBarcodeUniqueViolation(DatabaseException error) {
  return error.isUniqueConstraintError(
    'local_products.isletme_id, local_products.barcode',
  );
}

String productMutationErrorMessage(Object error) {
  if (error is DuplicateProductBarcodeException ||
      (error is PostgrestException && isTenantBarcodeUniqueViolation(error))) {
    return duplicateProductBarcodeMessage;
  }

  return 'Hata: $error';
}
