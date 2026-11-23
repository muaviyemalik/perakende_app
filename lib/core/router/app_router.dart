import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/admin/presentation/screens/add_product_screen.dart';
import '../../features/admin/presentation/screens/admin_dashboard_screen.dart';
import '../../features/admin/presentation/screens/sales_history_screen.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/auth/presentation/screens/employee_dashboard_screen.dart';
import '../../features/auth/presentation/screens/force_change_password_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/products/presentation/screens/test_screen.dart';
import '../../features/admin/presentation/screens/edit_product_screen.dart';

/// Yalnızca admin rolünün açabileceği rotalar.
const adminOnlyRoutes = {
  '/admin-dashboard',
  '/add-product',
  '/sales-history',
  '/edit-product',
};

/// Profil bilgisi gerektiren (giriş/şifre ekranı dışındaki) paneller.
const _protectedRoutes = {...adminOnlyRoutes, '/employee-dashboard'};

/// Router yönlendirme kuralları — test edilebilmesi için saf fonksiyon.
///
/// Eskiden rol yalnızca ana sayfa seçiminde kullanılıyordu; kasiyer
/// `/admin-dashboard` gibi rotalara doğrudan gidebiliyordu. Profil
/// yüklenirken de istenen her rotaya izin veriliyordu.
String? resolveAppRedirect({
  required String location,
  required bool isLoggedIn,
  required bool profileLoading,
  required KullaniciLoadResult? profile,
  Object? extra,
}) {
  // go_router rotaları büyük/küçük harfe duyarsız eşleştirir: "/ADMIN-DASHBOARD"
  // admin ekranını açar. Kontroller aynı şekilde normalleştirilmiş yol
  // üzerinde yapılmazsa rol kontrolü atlatılabilir.
  location = location.toLowerCase();
  if (location.length > 1 && location.endsWith('/')) {
    location = location.substring(0, location.length - 1);
  }

  if (!isLoggedIn) {
    return location == '/login' ? null : '/login';
  }

  // Profil (rol) henüz bilinmiyorken korumalı bir panel açılmasın.
  if (profileLoading) {
    return _protectedRoutes.contains(location) ? '/' : null;
  }

  if (profile?.kullaniciYuklenemedi ?? false) {
    return location == '/login' ? null : '/login';
  }

  final data = profile?.data;
  if (data == null) {
    return _protectedRoutes.contains(location) ? '/' : null;
  }

  if (!data.sifreDegistiMi) {
    return location == '/force-change-password'
        ? null
        : '/force-change-password';
  }

  final home = dashboardPathForRol(data.rol);

  if (location == '/login' ||
      location == '/force-change-password' ||
      location == '/') {
    if (home != null && home != location) return home;
    return location == '/' ? null : '/';
  }

  if (adminOnlyRoutes.contains(location) && data.rol != 'admin') {
    return home ?? '/login';
  }

  // Düzenlenecek ürün olmadan (ör. yenileme / derin bağlantı) açılırsa çökmesin.
  if (location == '/edit-product' && extra is! Map<String, dynamic>) {
    return '/admin-dashboard';
  }

  return null;
}

final appRouterProvider = Provider<GoRouter>((ref) {
  ref.watch(authStateProvider);
  final kullaniciAsync = ref.watch(kullaniciProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) => resolveAppRedirect(
      location: state.matchedLocation,
      isLoggedIn: Supabase.instance.client.auth.currentUser != null,
      profileLoading: kullaniciAsync.isLoading,
      profile: kullaniciAsync.maybeWhen(
        data: (result) => result,
        orElse: () => null,
      ),
      extra: state.extra,
    ),
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) {
          return const TestScreen();
        },
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) {
          return const LoginScreen();
        },
      ),
      GoRoute(
        path: '/force-change-password',
        builder: (context, state) {
          return const ForceChangePasswordScreen();
        },
      ),
      GoRoute(
        path: '/admin-dashboard',
        builder: (context, state) {
          return const AdminDashboardScreen();
        },
      ),
      GoRoute(
        path: '/employee-dashboard',
        builder: (context, state) {
          return const EmployeeDashboardScreen();
        },
      ),
      GoRoute(
        path: '/add-product',
        builder: (context, state) {
          return const AddProductScreen();
        },
      ),
      GoRoute(
        path: '/sales-history',
        builder: (context, state) {
          return const SalesHistoryScreen();
        },
      ),
      GoRoute(
        path: '/edit-product',
        builder: (context, state) {
          final product = state.extra as Map<String, dynamic>;
          return EditProductScreen(product: product);
        },
      ),
    ],
  );
});
