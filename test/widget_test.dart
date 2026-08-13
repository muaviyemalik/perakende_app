// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:perakende_app/app.dart';
import 'package:perakende_app/features/admin/presentation/screens/admin_dashboard_screen.dart';

void main() {
  testWidgets('App widget test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: App()),
    );

    expect(find.byType(App), findsOneWidget);
  });

  testWidgets('Admin dashboard shows a fixed 4-tab navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
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
    expect(find.text('Yönetim'), findsOneWidget);
    expect(find.text('Profil'), findsOneWidget);
  });

  testWidgets('Admin summary tab shows sales history button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AdminDashboardScreen(),
        ),
      ),
    );

    await tester.tap(find.text('Özet'));
    await tester.pumpAndSettle();

    expect(find.text('Satış Geçmişini Gör'), findsOneWidget);
  });
}
