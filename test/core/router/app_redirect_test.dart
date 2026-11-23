import 'package:flutter_test/flutter_test.dart';
import 'package:perakende_app/core/router/app_router.dart';
import 'package:perakende_app/features/auth/domain/kullanici_data.dart';

KullaniciLoadResult _profile(String rol, {bool sifreDegisti = true}) =>
    KullaniciLoadResult(
      data: KullaniciData(rol: rol, isletmeId: 1, sifreDegistiMi: sifreDegisti),
    );

String? _redirect(
  String location, {
  bool loggedIn = true,
  bool loading = false,
  KullaniciLoadResult? profile,
  Object? extra,
}) =>
    resolveAppRedirect(
      location: location,
      isLoggedIn: loggedIn,
      profileLoading: loading,
      profile: profile,
      extra: extra,
    );

void main() {
  test('logged out user is sent to login', () {
    expect(_redirect('/admin-dashboard', loggedIn: false), '/login');
    expect(_redirect('/login', loggedIn: false), isNull);
  });

  test('cashier cannot open admin-only routes', () {
    final kasiyer = _profile('kasiyer');
    for (final route in adminOnlyRoutes) {
      expect(
        _redirect(route, profile: kasiyer, extra: <String, dynamic>{}),
        '/employee-dashboard',
        reason: route,
      );
    }
    expect(_redirect('/employee-dashboard', profile: kasiyer), isNull);
  });

  test('case or trailing-slash variants cannot bypass the role check', () {
    final kasiyer = _profile('kasiyer');
    expect(_redirect('/ADMIN-DASHBOARD', profile: kasiyer),
        '/employee-dashboard');
    expect(_redirect('/Add-Product/', profile: kasiyer), '/employee-dashboard');
  });

  test('admin can open admin routes', () {
    final admin = _profile('admin');
    expect(_redirect('/admin-dashboard', profile: admin), isNull);
    expect(_redirect('/add-product', profile: admin), isNull);
    expect(
      _redirect('/edit-product',
          profile: admin, extra: <String, dynamic>{'id': 'x'}),
      isNull,
    );
  });

  test('protected routes wait while profile is loading', () {
    expect(_redirect('/admin-dashboard', loading: true), '/');
    expect(_redirect('/login', loading: true), isNull);
  });

  test('password not changed forces change screen', () {
    final kasiyer = _profile('kasiyer', sifreDegisti: false);
    expect(_redirect('/employee-dashboard', profile: kasiyer),
        '/force-change-password');
    expect(_redirect('/force-change-password', profile: kasiyer), isNull);
  });

  test('root and login go to role home', () {
    expect(_redirect('/', profile: _profile('admin')), '/admin-dashboard');
    expect(_redirect('/login', profile: _profile('kasiyer')),
        '/employee-dashboard');
  });

  test('edit-product without product does not crash', () {
    expect(_redirect('/edit-product', profile: _profile('admin')),
        '/admin-dashboard');
  });
}
