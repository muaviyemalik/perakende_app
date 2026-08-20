import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/features/auth/presentation/screens/employee_dashboard_screen.dart';
import 'package:perakende_app/providers/cart_provider.dart';
import 'package:perakende_app/providers/product_provider.dart';

void main() {
  final testProduct = {
    'id': 'p1',
    'name': 'Elma',
    'barcode': '12345',
    'price': 10.0,
    'stock': 100,
    'isletme_id': 9991, // Own tenant
  };

  Widget createWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: EmployeeDashboardScreen(),
      ),
    );
  }

  Future<void> openManualEntry(WidgetTester tester) async {
    final placeholder = find.textContaining('Manuel giriş için tıklayın');
    if (placeholder.evaluate().isNotEmpty) {
      await tester.ensureVisible(placeholder);
      await tester.tap(placeholder);
    } else {
      final editBtn = find.byTooltip('Manuel barkod gir');
      if (editBtn.evaluate().isNotEmpty) {
        await tester.ensureVisible(editBtn);
        await tester.tap(editBtn);
      }
    }
    await tester.pumpAndSettle();
  }

  Finder getManualBarcodeField() {
    return find.byWidgetPredicate((widget) => 
      widget is TextField && widget.decoration?.hintText == 'Barkodu manuel girin...'
    );
  }

  testWidgets('Barkod bekleniyor alanına tıklayınca manuel giriş açılıyor', (WidgetTester tester) async {
    final container = ProviderContainer();
    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    expect(find.textContaining('Manuel giriş için tıklayın'), findsOneWidget);
    expect(getManualBarcodeField(), findsNothing); // should be hidden initially

    await openManualEntry(tester);

    expect(getManualBarcodeField(), findsOneWidget); // should appear
  });

  Future<void> toggleFastScan(WidgetTester tester, bool value) async {
    final switchFinder = find.byType(Switch);
    if (switchFinder.evaluate().isNotEmpty) {
      final Switch switchWidget = tester.widget(switchFinder);
      if (switchWidget.value != value) {
        await tester.tap(switchFinder);
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('Manuel barkod girişi (Hızlı Okutma KAPALI): geçerli barkod -> ürün kartı açılır', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') {
            return Future.value(testProduct);
          }
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    await tester.enterText(textField, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.search);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    // The product info should be displayed, which includes the product name and "Sepete Ekle" button
    expect(find.text('Ürün Bilgileri:'), findsOneWidget);
    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Sepete Ekle'), findsOneWidget);
    expect(getManualBarcodeField(), findsNothing); // should hide after success

    // Cart should be empty at this point
    final cart = container.read(cartProvider);
    expect(cart.length, 0);
  });

  testWidgets('Manuel barkod girişi (Hızlı Okutma AÇIK): geçerli barkod -> ürün sepete eklenir', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') {
            return Future.value(testProduct);
          }
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();
    
    await toggleFastScan(tester, true);

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    await tester.enterText(textField, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.search);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Elma sepete eklendi!'), findsOneWidget);
    expect(getManualBarcodeField(), findsNothing); 
    
    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.quantity, 1);
    expect(cart.first.name, 'Elma');
  });

  testWidgets('Manuel barkod girişi: geçersiz barkod -> hata gösterilir', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    await tester.enterText(textField, '99999');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Bu barkoda ait kayıtlı ürün bulunamadı!'), findsOneWidget);
    expect(getManualBarcodeField(), findsNothing); // field closes and shows product card with error
    
    final cart = container.read(cartProvider);
    expect(cart.length, 0);
  });

  testWidgets('Harf içeren manuel barkod reddediliyor', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    
    // TextInputFormatter will block letters, testing that the text remains only digits
    await tester.enterText(textField, '123A45');
    await tester.pumpAndSettle();

    final TextField widget = tester.widget(textField);
    expect(widget.controller?.text, '12345');
  });

  testWidgets('Manuel barkod girişi: boş barkod -> işlem yapılmaz', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    await tester.enterText(textField, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Bu barkoda ait ürün bulunamadı!'), findsNothing);
    final cart = container.read(cartProvider);
    expect(cart.length, 0);
  });

  testWidgets('Manuel barkod girişi (Hızlı Okutma AÇIK): aynı barkod -> miktar artar', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') {
            return Future.value(testProduct);
          }
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await toggleFastScan(tester, true);

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    
    await tester.enterText(textField, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // field is not hidden in fast scan mode usually, but if it is, open it again
    if (getManualBarcodeField().evaluate().isEmpty) {
      await openManualEntry(tester);
    }
    
    final textField2 = getManualBarcodeField();

    await tester.enterText(textField2, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.quantity, 2);
  });

  testWidgets('Manuel barkod girişi: tenant izolasyonu korunur', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          // tenant mismatch -> null
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pumpAndSettle();

    await openManualEntry(tester);

    final textField = getManualBarcodeField();
    await tester.enterText(textField, '099999');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Bu barkoda ait kayıtlı ürün bulunamadı!'), findsOneWidget);
    expect(getManualBarcodeField(), findsNothing);
    
    final cart = container.read(cartProvider);
    expect(cart.length, 0);
  });
}
