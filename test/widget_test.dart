// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:perakende_app/app.dart';
import 'package:perakende_app/core/providers/supabase_provider.dart';
import 'package:perakende_app/core/router/app_router.dart';
import 'package:perakende_app/features/admin/presentation/screens/admin_dashboard_screen.dart';
import 'package:perakende_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:perakende_app/providers/dashboard_stats_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeSupabaseClient extends Fake implements SupabaseClient {
  @override
  RealtimeChannel channel(
    String name, {
    RealtimeChannelConfig opts = const RealtimeChannelConfig(),
  }) {
    return FakeRealtimeChannel();
  }
}

class FakeRealtimeChannel extends Fake implements RealtimeChannel {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #onPostgresChanges ||
        invocation.memberName == #subscribe) {
      return this;
    }
    if (invocation.memberName == #unsubscribe) {
      return Future.value('ok');
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  testWidgets('App widget test', (WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(
            body: Text('Deterministic test shell'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          kullaniciProvider.overrideWith(
            (ref) async => const KullaniciLoadResult(),
          ),
        ],
        child: const App(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(App), findsOneWidget);
    expect(find.text('Deterministic test shell'), findsOneWidget);
  });

  testWidgets('Admin dashboard shows a fixed 4-tab navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(FakeSupabaseClient()),
        ],
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    final bottomNavigationBar = tester.widget<BottomNavigationBar>(
      find.byType(BottomNavigationBar),
    );

    expect(bottomNavigationBar.type, BottomNavigationBarType.fixed);
    expect(bottomNavigationBar.items.length, 4);
    expect(find.text('Okuyucu'), findsOneWidget);
    expect(find.text('Özet'), findsOneWidget);
    expect(find.text('Ürünler'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);
  });

  testWidgets('Admin summary tab shows sales history button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supabaseClientProvider.overrideWithValue(FakeSupabaseClient()),
          dashboardStatsProvider.overrideWith(
            (ref) async => {
              'totalProducts': 0,
              'criticalStock': 0,
              'criticalProductsList': <Map<String, dynamic>>[],
              'dailyRevenue': 0.0,
              'employeeSales': <Map<String, dynamic>>[],
            },
          ),
        ],
        child: const MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Özet'));
    await tester.pumpAndSettle();

    expect(find.text('Satış Geçmişini Gör'), findsOneWidget);
  });
}
