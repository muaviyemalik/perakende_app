import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/providers/supabase_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../providers/auth_provider.dart';
import '../../data/kullanici_servisi.dart';

const _logTag = 'AUTH';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late TextEditingController _emailController;
  late TextEditingController _passwordController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _cleanupFailedSession() async {
    await cleanupFailedAuthSession(ref);
  }

  Future<void> _handleLogin() async {
    if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
      _showErrorSnackBar('Lütfen email ve şifre girin');
      return;
    }

    setState(() => _isLoading = true);

    final supabase = ref.read(supabaseClientProvider);

    try {
      developer.log('Login başladı', name: _logTag);

      await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      developer.log('Auth başarılı', name: _logTag);

      final authUser = supabase.auth.currentUser;
      if (authUser == null) {
        _showErrorSnackBar('Kullanıcı bilgisi alınamadı');
        await _cleanupFailedSession();
        return;
      }

      developer.log('authUser.id = ${authUser.id}', name: _logTag);

      final kullanici = await ref
          .read(kullaniciServisiProvider)
          .getKullaniciByAuthId(authUser.id);

      developer.log(
        'isletme_id = ${kullanici.isletmeId}, rol = ${kullanici.rol}, '
        'sifre_degisti_mi = ${kullanici.sifreDegistiMi}',
        name: _logTag,
      );

      await LocalStorageService.saveIsletmeId(kullanici.isletmeId);

      ref.invalidate(kullaniciProvider);

      if (!mounted) return;

      final String hedef;
      if (!kullanici.sifreDegistiMi) {
        hedef = '/force-change-password';
      } else {
        hedef = dashboardPathForRol(kullanici.rol) ?? '/login';
        if (hedef == '/login') {
          _showErrorSnackBar(
            'Rolünüz için tanımlı bir panel bulunamadı (${kullanici.rol}). '
            'Lütfen yöneticinizle iletişime geçin.',
          );
          await _cleanupFailedSession();
          return;
        }
      }

      developer.log('yönlendirme = $hedef', name: _logTag);
      context.go(hedef);
    } on AuthException catch (e) {
      developer.log('Auth hatası — ${e.message}', name: _logTag, level: 900);
      final lowerMessage = e.message.toLowerCase();
      if (lowerMessage.contains('invalid') ||
          lowerMessage.contains('credentials') ||
          lowerMessage.contains('email not confirmed')) {
        _showErrorSnackBar('Email veya şifre hatalı.');
      } else {
        _showErrorSnackBar('Giriş hatası: ${e.message}');
      }
    } on KullaniciServisiException catch (e) {
      developer.log(
        'kullanici hatası — tip=${e.tip}, message=${e.message}',
        name: _logTag,
        level: 900,
      );
      if (shouldCleanupSessionOnKullaniciError(e.tip)) {
        await _cleanupFailedSession();
      }
      _showErrorSnackBar(e.message);
    } catch (e) {
      developer.log('beklenmeyen hata — $e', name: _logTag, level: 1000);
      await _cleanupFailedSession();
      _showErrorSnackBar('Beklenmeyen hata: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Giriş Yap'),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 40),
                const Text(
                  'Perakende Uygulaması',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Hesabınıza giriş yapın',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  enabled: !_isLoading,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'example@example.com',
                    prefixIcon: const Icon(Icons.email),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  enabled: !_isLoading,
                  decoration: InputDecoration(
                    labelText: 'Şifre',
                    hintText: '••••••••',
                    prefixIcon: const Icon(Icons.lock),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('Giriş Yap'),
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
