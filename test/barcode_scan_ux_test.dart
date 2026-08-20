import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/features/auth/presentation/screens/employee_dashboard_screen.dart';
import 'package:perakende_app/providers/cart_provider.dart';
import 'package:perakende_app/providers/product_provider.dart';

void main() {
  final testProducts = [
    {
      'id': 'p1',
      'name': 'Elma',
      'barcode': '12345',
      'price': 10.0,
      'stock': 100,
      'isletme_id': 9991,
    }
  ];

  testWidgets('Yavaş modda miktar kontrolü ve sepet akışı doğru çalışır',
      (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider('12345').overrideWith(
          (ref) => Future.value(testProducts.first),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: EmployeeDashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Manuel giriş alanını aç
    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    // Barkod gir ve ara
    await tester.enterText(find.byType(TextField).first, '12345');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // Ürün kartının açıldığını doğrula (Elma)
    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Fiyat: ₺10.00'), findsOneWidget);

    // Varsayılan miktar 1 olmalı
    expect(find.text('1'), findsOneWidget);

    // '+' butonuna basınca miktar 2 olur
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    // '+' butonuna tekrar basınca miktar 3 olur
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);

    // '-' butonuna basınca miktar 2 olur
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);

    // '-' butonuna basınca miktar 1 olur
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    // Miktar 1'in altına inemez (buton disabled)
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    // Miktarı 3 yapıp sepete ekleyelim
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('3'), findsOneWidget);

    // Sepete Ekle'ye bas
    await tester.tap(find.text('Sepete Ekle'));
    await tester.pumpAndSettle();

    // Sepete eklenen miktarın doğru olduğunu kontrol et
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.name, 'Elma');
    expect(cart.first.quantity, 3);

    // Sepete Ekle sonrası ürün kartı kapanmalı
    expect(find.text('Sepete Ekle'), findsNothing);

    // Sepete Ekle sonrası "Barkod bekleniyor" görünmeli
    expect(find.textContaining('Barkod bekleniyor'), findsOneWidget);
  });

  testWidgets('Hızlı okutma davranışı değişmez', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider('12345').overrideWith(
          (ref) => Future.value(testProducts.first),
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: EmployeeDashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Hızlı okutma modunu aç
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    // Manuel giriş alanını aç
    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    // Barkod gir ve ara
    await tester.enterText(find.byType(TextField).first, '12345');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle(); // Ürünün eklenmesini bekle

    // Ürün kartı HİÇ açılmamalı
    expect(find.text('Sepete Ekle'), findsNothing);

    // Sepete doğrudan 1 adet eklenmiş olmalı
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.name, 'Elma');
    expect(cart.first.quantity, 1);

    // "Barkod bekleniyor" görünmeye devam etmeli (veya manuel giriş açık kalabilir ama ürün kartı açılmaz)
    expect(find.textContaining('Barkod bekleniyor') , findsOneWidget);
  });
}
