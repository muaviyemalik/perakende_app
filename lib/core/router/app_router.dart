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

String? _homeDestination(AsyncValue<String?> kullaniciRol) {
  return kullaniciRol.maybeWhen(
    data: (rol) => dashboardPathForRol(rol),
    orElse: () => null,
  );
}

final appRouterProvider = Provider<GoRouter>((ref) {
  ref.watch(authStateProvider);
  final kullaniciRol = ref.watch(userRoleProvider);
  final kullaniciAsync = ref.watch(kullaniciProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isLoggedIn =
          Supabase.instance.client.auth.currentUser != null;

      if (!isLoggedIn) {
        if (location == '/login') {
          return null;
        }
        return '/login';
      }

      if (kullaniciAsync.isLoading) {
        return null;
      }

      final kullaniciResult = kullaniciAsync.maybeWhen(
        data: (result) => result,
        orElse: () => null,
      );

      if (kullaniciResult?.kullaniciYuklenemedi ?? false) {
        if (location == '/login') {
          return null;
        }
        return '/login';
      }

      final sifreDegistiMi = kullaniciResult?.data?.sifreDegistiMi;

      if (sifreDegistiMi == null) {
        return null;
      }

      if (!sifreDegistiMi) {
        if (location == '/force-change-password') {
          return null;
        }
        return '/force-change-password';
      }

      if (location == '/login' || location == '/force-change-password') {
        return _homeDestination(kullaniciRol) ?? '/';
      }

      if (location == '/') {
        final dashboard = _homeDestination(kullaniciRol);
        if (dashboard != null && dashboard != location) {
          return dashboard;
        }
      }

      return null;
    },
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
