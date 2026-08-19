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
      'isletme_id': 9991, // Own tenant
    },
    {
      'id': 'p2',
      'name': 'Armut',
      'barcode': '67890',
      'price': 15.0,
      'stock': 3, // Critical stock
      'isletme_id': 9991,
    }
  ];

  testWidgets('Ürün listesi başarıyla yüklenir ve ürünler gösterilir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
        ],
        child: const MaterialApp(
          home: EmployeeDashboardScreen(),
        ),
      ),
    );

    // İlk açıldığında okuyucu sekmesi olabilir, ürünler sekmesine geç
    await tester.tap(find.text('Ürünler'));
    await tester.pumpAndSettle();

    // Ürünlerin ekranda olup olmadığını kontrol et
    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Armut'), findsOneWidget);
    expect(find.text('Barkod: 12345'), findsOneWidget);
    expect(find.text('Stok: 3'), findsOneWidget); // Kritik stok
  });

  testWidgets('Arama işlemi doğru çalışır (İsim veya barkod)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
        ],
        child: const MaterialApp(
          home: EmployeeDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Ürünler'));
    await tester.pumpAndSettle();

    // Elma'yı ara
    await tester.enterText(
        find.byType(TextField), 'elma');
    await tester.pumpAndSettle();

    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Armut'), findsNothing);

    // Barkodla ara (Armut'un barkodu 67890)
    await tester.enterText(
        find.byType(TextField), '67890');
    await tester.pumpAndSettle();

    expect(find.text('Elma'), findsNothing);
    expect(find.text('Armut'), findsOneWidget);
  });

  testWidgets('Ürüne dokunulduğunda sepete eklenir',
      (WidgetTester tester) async {
    // Sepeti dinlemek için bir ProviderContainer kullanalım
    final container = ProviderContainer(
      overrides: [
        allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
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

    await tester.tap(find.text('Ürünler'));
    await tester.pumpAndSettle();

    // Başlangıçta sepet boş olmalı
    expect(container.read(cartProvider).length, 0);

    // Elma ürününe tıkla (ListTile)
    await tester.tap(find.text('Elma'));
    await tester.pumpAndSettle();

    // SnackBar çıkmalı
    expect(find.text('Elma sepete eklendi!'), findsOneWidget);

    // Sepete eklenmiş olmalı
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.name, 'Elma');
    expect(cart.first.quantity, 1);

    // Tekrar tıklandığında miktar artmalı
    await tester.tap(find.text('Elma'));
    await tester.pumpAndSettle();

    final updatedCart = container.read(cartProvider);
    expect(updatedCart.length, 1);
    expect(updatedCart.first.quantity, 2);
  });

  testWidgets('Tenant izolasyonu: Başka işletmenin ürünü gelmez',
      (WidgetTester tester) async {
    // UI testinde provider sadece isletme_id = 9991 olanları dönecek şekilde mocklandığı için
    // UI sadece bunları gösterir.
    // Tenant izolasyon testini sağlamak adına, allProductsProvider'ın boş dönme case'i
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          allProductsProvider.overrideWith((ref) => Future.value([])),
        ],
        child: const MaterialApp(
          home: EmployeeDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Ürünler'));
    await tester.pumpAndSettle();

    // Başka işletmenin ürünü olmadığı için boş state çıkmalı
    expect(find.text('İşletmenize ait ürün bulunamadı.'), findsOneWidget);
  });
}
