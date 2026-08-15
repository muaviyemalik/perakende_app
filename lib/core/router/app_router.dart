import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/screens/add_product_screen.dart';
import '../../features/admin/presentation/screens/admin_dashboard_screen.dart';
import '../../features/admin/presentation/screens/sales_history_screen.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/auth/presentation/screens/employee_dashboard_screen.dart';
import '../../features/auth/presentation/screens/login_screen.dart';
import '../../features/products/presentation/screens/test_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // Watch the auth state to enable redirect logic
  final authState = ref.watch(authStateProvider);
  final userRole = ref.watch(userRoleProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      // Check if user is authenticated
      final isLoggedIn = authState.maybeWhen(
        data: (session) => session != null,
        orElse: () => false,
      );

      // If not logged in, redirect to login
      if (!isLoggedIn) {
        if (state.matchedLocation != '/login') {
          return '/login';
        }
        return null;
      }

      // If logged in and on login page, redirect based on role
      if (state.matchedLocation == '/login') {
        return userRole.maybeWhen(
          data: (role) {
            if (role == 'admin') {
              return '/admin-dashboard';
            } else if (role == 'employee') {
              return '/employee-dashboard';
            }
            return '/';
          },
          orElse: () => '/',
        );
      }

      // If on home page and logged in, redirect based on role
      if (state.matchedLocation == '/') {
        return userRole.maybeWhen(
          data: (role) {
            if (role == 'admin') {
              return '/admin-dashboard';
            } else if (role == 'employee') {
              return '/employee-dashboard';
            }
            return '/';
          },
          orElse: () => '/',
        );
      }

      // No redirect needed
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
    ],
  );
});
