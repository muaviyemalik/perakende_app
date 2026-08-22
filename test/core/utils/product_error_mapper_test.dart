import 'package:flutter_test/flutter_test.dart';
import 'package:perakende_app/core/utils/product_error_mapper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('productMutationErrorMessage', () {
    test('maps the tenant barcode index unique violation', () {
      const error = PostgrestException(
        message:
            'duplicate key value violates unique constraint "idx_products_unique_barcode"',
        code: '23505',
      );

      expect(
          productMutationErrorMessage(error), duplicateProductBarcodeMessage);
    });

    test('does not map another unique constraint violation', () {
      const error = PostgrestException(
        message:
            'duplicate key value violates unique constraint "another_unique_index"',
        code: '23505',
      );

      expect(productMutationErrorMessage(error), startsWith('Hata:'));
      expect(productMutationErrorMessage(error),
          isNot(duplicateProductBarcodeMessage));
    });

    test('does not map the index name without PostgreSQL unique code', () {
      const error = PostgrestException(
        message: 'idx_products_unique_barcode',
        code: '42501',
      );

      expect(productMutationErrorMessage(error), startsWith('Hata:'));
    });
  });
}
