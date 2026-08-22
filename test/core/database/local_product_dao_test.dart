import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:perakende_app/core/database/local_database.dart';
import 'package:perakende_app/core/database/local_product_dao.dart';
import 'package:perakende_app/core/utils/product_error_mapper.dart';

import 'sqlite_test_helper.dart';

void main() {
  setUpAll(() {
    setupSqfliteTestHelper();
  });

  group('LocalProductDao Tests', () {
    late LocalProductDao dao;
    late Database db;

    setUp(() async {
      // Testler için temiz bir DB kullanmak amacıyla
      // LocalDatabase singleton'ı normalde perakende_local.db açar
      // Testlerde in-memory kullanmak zor çünkü singleton içindeki isim sabit.
      // Biz sadece veritabanını temizleyip kullanabiliriz.
      dao = LocalProductDao.instance;
      db = await LocalDatabase.instance.database;
      await db.delete('local_products');
    });

    tearDownAll(() async {
      await LocalDatabase.instance.close();
    });

    test('upsertBatch and getAllActive works correctly', () async {
      final p1 = LocalProduct(
        id: 'p1',
        isletmeId: 1,
        barcode: '111',
        name: 'Ürün 1',
        price: 10,
        stock: 5,
        updatedAt: DateTime.parse('2024-01-01T10:00:00Z'),
      );

      await dao.upsertBatch(isletmeId: 1, products: [p1]);

      var active = await dao.getAllActive(1);
      expect(active.length, 1);
      expect(active.first.name, 'Ürün 1');
    });

    test('Tenant isolation works', () async {
      final p1 = LocalProduct(
        id: 'p1',
        isletmeId: 1,
        barcode: '111',
        name: 'Ürün 1',
        price: 10,
        stock: 5,
        updatedAt: DateTime.now(),
      );
      final p2 = LocalProduct(
        id: 'p2',
        isletmeId: 2,
        barcode: '222',
        name: 'Ürün 2',
        price: 20,
        stock: 10,
        updatedAt: DateTime.now(),
      );

      await dao.upsertBatch(isletmeId: 1, products: [p1]);
      await dao.upsertBatch(isletmeId: 2, products: [p2]);

      final activeTenant1 = await dao.getAllActive(1);
      expect(activeTenant1.length, 1);
      expect(activeTenant1.first.id, 'p1');

      final activeTenant2 = await dao.getAllActive(2);
      expect(activeTenant2.length, 1);
      expect(activeTenant2.first.id, 'p2');
    });

    test('Soft delete filters out deleted products', () async {
      final p1 = LocalProduct(
        id: 'p1',
        isletmeId: 1,
        barcode: '111',
        name: 'Ürün 1',
        price: 10,
        stock: 5,
        updatedAt: DateTime.now(),
      );
      await dao.upsertBatch(isletmeId: 1, products: [p1]);

      await dao.softDelete(id: 'p1', isletmeId: 1);

      final active = await dao.getAllActive(1);
      expect(active.isEmpty, true);

      final byBarcode = await dao.getByBarcode(barcode: '111', isletmeId: 1);
      expect(byBarcode, isNull);
    });

    test(
        'Barcode uniqueness works: throws on conflict, different tenant allows same barcode',
        () async {
      final p1 = LocalProduct(
        id: 'p1',
        isletmeId: 1,
        barcode: '12345',
        name: 'Ürün 1',
        price: 10,
        stock: 5,
        updatedAt: DateTime.now(),
      );
      final p2 = LocalProduct(
        id: 'p2',
        isletmeId: 1, // Aynı tenant, aynı barkod
        barcode: '12345',
        name: 'Ürün 1 Yeni',
        price: 15,
        stock: 10,
        updatedAt: DateTime.now(),
      );
      final p3 = LocalProduct(
        id: 'p3',
        isletmeId: 2, // Farklı tenant, aynı barkod
        barcode: '12345',
        name: 'Ürün 1 Baska Isletme',
        price: 20,
        stock: 1,
        updatedAt: DateTime.now(),
      );

      await dao.upsertBatch(isletmeId: 1, products: [p1]);

      // Aynı işletme ve barkod ile yeni ID eklendiğinde exception fırlatılmalı (silent delete olmamalı)
      try {
        await dao.upsertBatch(isletmeId: 1, products: [p2]);
        fail('Should have thrown unique constraint exception');
      } catch (e) {
        expect(e.toString(), contains('UNIQUE constraint failed'));
        expect(e, isA<DatabaseException>());
        expect(
          isLocalTenantBarcodeUniqueViolation(e as DatabaseException),
          isTrue,
        );
      }

      // Farklı işletme, aynı barkod sorunsuz eklenir
      await dao.upsertBatch(isletmeId: 2, products: [p3]);

      final active1 = await dao.getAllActive(1);
      expect(active1.length, 1);
      expect(active1.first.id, 'p1'); // p1 korunmuş olmalı, replace edilmemeli

      final active2 = await dao.getAllActive(2);
      expect(active2.length, 1);
      expect(active2.first.id, 'p3'); // Farklı işletmede aynı barkod sorunsuz
    });

    test('Updating a product with its own barcode does not conflict', () async {
      await dao.upsertBatch(
        isletmeId: 1,
        products: [
          LocalProduct(
            id: 'p1',
            isletmeId: 1,
            barcode: '12345',
            name: 'Urun 1',
            price: 10,
            stock: 5,
            updatedAt: DateTime.now(),
          ),
        ],
      );
      await dao.updateLocal(
        id: 'p1',
        isletmeId: 1,
        barcode: '12345',
        name: 'Urun 1 Guncel',
        price: 12,
        stock: 7,
      );

      final product = await dao.getById(id: 'p1', isletmeId: 1);
      expect(product?.barcode, '12345');
      expect(product?.name, 'Urun 1 Guncel');
    });

    test('A soft-deleted product barcode can be reused', () async {
      await dao.upsertBatch(
        isletmeId: 1,
        products: [
          LocalProduct(
            id: 'p1',
            isletmeId: 1,
            barcode: '12345',
            name: 'Eski Urun',
            price: 10,
            stock: 5,
            updatedAt: DateTime.now(),
          ),
        ],
      );
      await dao.softDelete(id: 'p1', isletmeId: 1);
      await dao.createLocal(
        isletmeId: 1,
        barcode: '12345',
        name: 'Yeni Urun',
        price: 15,
        stock: 3,
      );

      final active = await dao.getAllActive(1);
      expect(active, hasLength(1));
      expect(active.single.name, 'Yeni Urun');
    });

    test('Null barcodes are allowed multiple times', () async {
      final p1 = LocalProduct(
        id: 'p1',
        isletmeId: 1,
        barcode: null,
        name: 'Ürün 1',
        price: 10,
        stock: 5,
        updatedAt: DateTime.now(),
      );
      final p2 = LocalProduct(
        id: 'p2',
        isletmeId: 1,
        barcode: null,
        name: 'Ürün 2',
        price: 15,
        stock: 10,
        updatedAt: DateTime.now(),
      );

      await dao.upsertBatch(isletmeId: 1, products: [p1, p2]);

      final active = await dao.getAllActive(1);
      expect(active.length, 2); // Null barkodlar unique constraintine takılmaz
    });
  });
}
