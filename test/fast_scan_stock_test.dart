import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/features/auth/presentation/screens/employee_dashboard_screen.dart';
import 'package:perakende_app/providers/cart_provider.dart';
import 'package:perakende_app/providers/product_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final testProducts = [
    {
      'id': 'p1',
      'name': 'Elma',
      'barcode': '12345',
      'price': 10.0,
      'stock': 0, // Senaryo 1 için
      'isletme_id': 9991,
    },
    {
      'id': 'p2',
      'name': 'Armut',
      'barcode': '54321',
      'price': 20.0,
      'stock': 5, // Senaryo 2, 3, 4 için
      'isletme_id': 9991,
    }
  ];

  Future<ProviderContainer> setupContainer() async {
    return ProviderContainer(
      overrides: [
        productByBarcodeProvider('12345').overrideWith(
          (ref) => Future.value(testProducts[0]),
        ),
        productByBarcodeProvider('54321').overrideWith(
          (ref) => Future.value(testProducts[1]),
        ),
      ],
    );
  }

  testWidgets('1. stock = 0 -> hızlı okut -> sepete eklenmemeli', (WidgetTester tester) async {
    final container = await setupContainer();

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

    // Manuel barkod girişi ile test ediyoruz (hızlı okutma akışıyla aynı methodu çağırır)
    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '12345');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // Eklenmemeli
    final cart = container.read(cartProvider);
    expect(cart.length, 0);

    // Uyarı göstermeli
    expect(find.text('Bu ürün stokta yok.'), findsOneWidget);
  });

  testWidgets('2. stock = 5, sepette 5 -> hızlı okut -> eklenmemeli', (WidgetTester tester) async {
    final container = await setupContainer();
    
    // Sepete önceden 5 tane ekle
    container.read(cartProvider.notifier).addToCart(
      productId: 'p2',
      name: 'Armut',
      price: 20.0,
      stock: 5,
      quantity: 5,
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

    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '54321');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // Miktar 5 olarak kalmalı
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.quantity, 5);
    
    // Uyarı göstermeli
    expect(find.text('Stokta yalnızca 5 adet bulunuyor.'), findsOneWidget);
  });

  testWidgets('3. stock = 5, sepette 4 -> hızlı okut -> 1 adet eklenmeli', (WidgetTester tester) async {
    final container = await setupContainer();
    
    // Sepete önceden 4 tane ekle
    container.read(cartProvider.notifier).addToCart(
      productId: 'p2',
      name: 'Armut',
      price: 20.0,
      stock: 5,
      quantity: 4,
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

    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '54321');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // Miktar 5 olmalı
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.quantity, 5);
    
    // Başarı mesajı
    expect(find.text('Armut sepete eklendi!'), findsOneWidget);
  });

  testWidgets('4. stock = 5, sepette 0 -> hızlı okut -> 1 adet eklenebilmeli', (WidgetTester tester) async {
    final container = await setupContainer();

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

    await tester.tap(find.textContaining('Manuel giriş için tıklayın'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '54321');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    // Miktar 1 olmalı
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.quantity, 1);
    
    // Başarı mesajı
    expect(find.text('Armut sepete eklendi!'), findsOneWidget);
  });
}
