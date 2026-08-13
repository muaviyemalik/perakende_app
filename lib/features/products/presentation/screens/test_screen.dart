import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/supabase_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';

// FutureProvider to fetch products from Supabase
final productsProvider = FutureProvider<List<dynamic>>((ref) async {
  final supabase = ref.watch(supabaseClientProvider);
  final response = await supabase.from('products').select('*');
  return response as List<dynamic>;
});

class TestScreen extends ConsumerStatefulWidget {
  const TestScreen({super.key});

  @override
  ConsumerState<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends ConsumerState<TestScreen> {
  bool _isLoggingOut = false;

  Future<void> _handleLogout() async {
    setState(() => _isLoggingOut = true);

    try {
      final supabase = ref.read(supabaseClientProvider);
      await supabase.auth.signOut();
      // Router'ın redirect mantığı otomatik olarak /login'e yönlendirecek
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Çıkış hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoggingOut = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(productsProvider);
    final authState = ref.watch(authStateProvider);
    final userRole = ref.watch(userRoleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Ekranı - Supabase Bağlantısı'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış Yap',
            onPressed: _isLoggingOut ? null : _handleLogout,
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Auth Session Status
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Oturum Durumu:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        authState.when(
                          data: (session) {
                            return Text(
                              session == null
                                  ? 'Giriş yapılmamış'
                                  : 'Email: ${session.user.email}',
                              style: const TextStyle(fontSize: 14),
                            );
                          },
                          loading: () => const Text(
                            'Yükleniyor...',
                            style: TextStyle(fontSize: 14),
                          ),
                          error: (error, stack) => const Text(
                            'Oturum bilgisi alınamadı',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Role Information
                        userRole.when(
                          data: (role) {
                            final roleText =
                                role == 'admin' ? 'Admin' : 'Çalışan';
                            return Text(
                              'Rol: $roleText',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: role == 'admin'
                                    ? Colors.red.shade700
                                    : Colors.green.shade700,
                              ),
                            );
                          },
                          loading: () => const Text(
                            'Rol yükleniyor...',
                            style: TextStyle(fontSize: 14),
                          ),
                          error: (error, stack) => const Text(
                            'Rol bilgisi alınamadı',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Products Data Status
                Card(
                  color: Colors.green.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ürünler (Products Tablosu):',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        productsAsync.when(
                          data: (products) {
                            return Text(
                              'Bağlantı başarılı, ${products.length} ürün bulundu',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.green,
                              ),
                            );
                          },
                          loading: () {
                            return const SizedBox(
                              width: 24,
                              height: 24,
                              child: Padding(
                                padding: EdgeInsets.only(right: 8.0),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          },
                          error: (error, stackTrace) {
                            return Text(
                              'Hata: $error',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.red,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
