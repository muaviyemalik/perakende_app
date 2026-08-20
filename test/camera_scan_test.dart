import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
  
  final testProductB = {
    'id': 'p2',
    'name': 'Armut',
    'barcode': '67890',
    'price': 15.0,
    'stock': 100,
    'isletme_id': 9991, 
  };

  Widget createWidget(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: EmployeeDashboardScreen(),
      ),
    );
  }

  Future<void> toggleFastScan(WidgetTester tester, bool value) async {
    final switchFinder = find.byType(Switch);
    if (switchFinder.evaluate().isNotEmpty) {
      final Switch switchWidget = tester.widget(switchFinder);
      if (switchWidget.value != value) {
        await tester.tap(switchFinder);
        await tester.pump();
      }
    }
  }

  void simulateScan(WidgetTester tester, String barcode) {
    final scannerFinder = find.byType(MobileScanner);
    expect(scannerFinder, findsOneWidget);
    final MobileScanner scanner = tester.widget(scannerFinder);
    scanner.onDetect!(BarcodeCapture(barcodes: [Barcode(rawValue: barcode)]));
  }

  testWidgets('Aynı barkod tek scan -> 1 işlem (Hızlı Okutma KAPALI)', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') return Future.value(testProduct);
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pump();

    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    
    // Should show product card
    expect(find.text('Elma'), findsOneWidget);
  });

  testWidgets('Aynı barkod kamera önünde sabit -> sadece 1 işlem', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') return Future.value(testProduct);
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pump();

    await toggleFastScan(tester, true);

    // İlk scan
    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(cartProvider).length, 1);
    expect(container.read(cartProvider).first.quantity, 1);

    // 200ms sonra tekrar scan (kamerada sabit duruyor)
    sleep(const Duration(milliseconds: 200));
    await tester.pump();
    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Miktar aynı kalmalı
    expect(container.read(cartProvider).first.quantity, 1);

    // 400ms sonra tekrar
    sleep(const Duration(milliseconds: 400));
    await tester.pump();
    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(cartProvider).first.quantity, 1);
  });

  testWidgets('Barkod kameradan çıkıp tekrar giriyor -> yeni scan', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') return Future.value(testProduct);
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pump();

    await toggleFastScan(tester, true);

    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(cartProvider).first.quantity, 1);

    // Kameradan çıktı ve 1.6 saniye geçti
    sleep(const Duration(milliseconds: 1600));
    await tester.pump();

    // Tekrar girdi
    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Miktar artmalı
    expect(container.read(cartProvider).first.quantity, 2);
  });

  testWidgets('Farklı barkodlar arka arkaya okutulabiliyor', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        productByBarcodeProvider.overrideWith((ref, barcode) {
          if (barcode == '12345') return Future.value(testProduct);
          if (barcode == '67890') return Future.value(testProductB);
          return Future.value(null);
        }),
      ],
    );

    await tester.pumpWidget(createWidget(container));
    await tester.pump();

    await toggleFastScan(tester, true);

    simulateScan(tester, '12345');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    
    // Anında farklı barkod
    sleep(const Duration(milliseconds: 100));
    await tester.pump();
    simulateScan(tester, '67890');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(cartProvider).length, 2);
  });
}
