import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/features/admin/presentation/screens/edit_product_screen.dart';
import 'package:perakende_app/providers/product_provider.dart';
import 'package:perakende_app/core/utils/product_error_mapper.dart';
import 'package:go_router/go_router.dart';

void main() {
  final testProduct = {
    'id': 'p1',
    'name': 'Elma',
    'barcode': '12345',
    'price': 10.0,
    'stock': 100,
    'isletme_id': 9991,
  };

  testWidgets('EditProductScreen - Mevcut ürün bilgileri forma doğru gelir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('10.0'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
  });

  testWidgets('EditProductScreen - Boş isim reddedilir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), '');
    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Ürün adı gerekli'), findsOneWidget);
  });

  testWidgets('EditProductScreen - Geçersiz fiyat reddedilir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(1), 'abc');
    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Geçerli bir fiyat girin'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), '-5');
    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Fiyat 0\'dan küçük olamaz'), findsOneWidget);
  });

  testWidgets('EditProductScreen - Negatif stok reddedilir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(2), '-10');
    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('Stok negatif olamaz'), findsOneWidget);
  });

  testWidgets(
      'EditProductScreen - Harfli barkod reddedilir (Input Formatter Testi)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Harfli bir barkod girmeyi denersek, BarcodeUtils.barcodeInputFormatters bunu engeller.
    // '123A45' girildiğinde formatter 'A' harfini siler ve geriye '12345' kalır.
    await tester.enterText(find.byType(TextFormField).at(3), '123A45');
    await tester.pumpAndSettle();

    // TextField içindeki text '123A45' değil '12345' olmalıdır.
    expect(find.text('12345'), findsWidgets);
  });

  testWidgets('EditProductScreen - Geçerli bilgilerle provider çağrılır',
      (WidgetTester tester) async {
    bool isUpdateCalled = false;

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(
          path: '/edit',
          builder: (context, state) => EditProductScreen(product: testProduct),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateProductProvider.overrideWith((ref) {
            return (String id, Map<String, dynamic> data) async {
              expect(id, 'p1');
              expect(data['name'], 'Yeni Elma');
              expect(data['price'], 15.0);
              expect(data['stock'], 200);
              expect(data['barcode'], '123456');
              isUpdateCalled = true;
            };
          }),
        ],
        child: MaterialApp.router(
          routerConfig: router,
        ),
      ),
    );

    router.push('/edit');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Yeni Elma');
    await tester.enterText(find.byType(TextFormField).at(1), '15.0');
    await tester.enterText(find.byType(TextFormField).at(2), '200');
    await tester.enterText(find.byType(TextFormField).at(3), '123456');

    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pumpAndSettle();

    expect(isUpdateCalled, true);
    expect(find.text('Ürün başarıyla güncellendi'), findsOneWidget);
  });

  testWidgets('EditProductScreen - duplicate barcode friendly error gösterir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateProductProvider.overrideWith((ref) {
            return (String id, Map<String, dynamic> data) async {
              throw const DuplicateProductBarcodeException();
            };
          }),
        ],
        child: MaterialApp(
          home: EditProductScreen(product: testProduct),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Değişiklikleri Kaydet'));
    await tester.pump();

    expect(find.text(duplicateProductBarcodeMessage), findsOneWidget);
    expect(find.textContaining('PostgrestException'), findsNothing);
  });
}
