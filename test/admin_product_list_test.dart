import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/features/admin/presentation/screens/admin_dashboard_screen.dart';
import 'package:perakende_app/providers/cart_provider.dart';
import 'package:perakende_app/providers/product_provider.dart';
import 'package:perakende_app/core/providers/supabase_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeSupabaseClient extends Fake implements SupabaseClient {
  @override
  RealtimeChannel channel(String name, {RealtimeChannelConfig opts = const RealtimeChannelConfig()}) {
    return FakeRealtimeChannel();
  }
}

class FakeRealtimeChannel extends Fake implements RealtimeChannel {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #onPostgresChanges) {
      return this;
    }
    if (invocation.memberName == #subscribe) {
      return this;
    }
    if (invocation.memberName == #unsubscribe) {
      return Future.value('ok');
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final fakeSupabase = FakeSupabaseClient();
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

  testWidgets('Admin - Ürün listesi başarıyla yüklenir ve ürünler gösterilir',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(fakeSupabase),
          allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
        ],
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    // İlk açıldığında okuyucu sekmesi açılır, Ürünler sekmesine geç (index 2)
    await tester.tap(find.byIcon(Icons.shopping_bag));
    await tester.pumpAndSettle();

    // Ürünlerin ekranda olup olmadığını kontrol et
    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Armut'), findsOneWidget);
    expect(find.text('Barkod: 12345'), findsOneWidget);
    expect(find.text('Stok: 3'), findsOneWidget); // Kritik stok
    
    // Yönetim butonları yerinde durmalı
    expect(find.text('Yeni Ürün'), findsOneWidget);
  });

  testWidgets('Admin - Arama işlemi doğru çalışır (İsim veya barkod)',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(fakeSupabase),
          allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
        ],
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.shopping_bag));
    await tester.pumpAndSettle();

    // Elma'yı ara
    await tester.enterText(find.byType(TextField), 'elma');
    await tester.pumpAndSettle();

    expect(find.text('Elma'), findsOneWidget);
    expect(find.text('Armut'), findsNothing);

    // Barkodla ara (Armut'un barkodu 67890)
    await tester.enterText(find.byType(TextField), '67890');
    await tester.pumpAndSettle();

    expect(find.text('Elma'), findsNothing);
    expect(find.text('Armut'), findsOneWidget);
  });

  testWidgets('Admin - Ürüne dokunulduğunda sepete eklenir',
      (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        supabaseClientProvider.overrideWithValue(fakeSupabase),
        allProductsProvider.overrideWith((ref) => Future.value(testProducts)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.shopping_bag));
    await tester.pumpAndSettle();

    expect(container.read(cartProvider).length, 0);

    // Elma ürününe tıkla (ListTile)
    await tester.tap(find.text('Elma'));
    await tester.pumpAndSettle();

    expect(find.text('Elma sepete eklendi!'), findsOneWidget);

    final cart = container.read(cartProvider);
    expect(cart.length, 1);
    expect(cart.first.name, 'Elma');
    expect(cart.first.quantity, 1);

    await tester.tap(find.text('Elma'));
    await tester.pumpAndSettle();

    final updatedCart = container.read(cartProvider);
    expect(updatedCart.length, 1);
    expect(updatedCart.first.quantity, 2);
  });

  testWidgets('Admin - Empty state', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(fakeSupabase),
          allProductsProvider.overrideWith((ref) => Future.value([])),
        ],
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.shopping_bag));
    await tester.pumpAndSettle();

    expect(find.text('İşletmenize ait ürün bulunamadı.'), findsOneWidget);
  });
}
