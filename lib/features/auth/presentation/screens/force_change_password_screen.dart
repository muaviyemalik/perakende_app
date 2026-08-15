import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/providers/supabase_provider.dart';
import '../providers/auth_provider.dart';

const _logTag = 'AUTH';

class ForceChangePasswordScreen extends ConsumerStatefulWidget {
  const ForceChangePasswordScreen({super.key});

  @override
  ConsumerState<ForceChangePasswordScreen> createState() =>
      _ForceChangePasswordScreenState();
}

class _ForceChangePasswordScreenState
    extends ConsumerState<ForceChangePasswordScreen> {
  late TextEditingController _passwordController;
  late TextEditingController _passwordConfirmController;
  bool _isLoading = false;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
    _passwordConfirmController = TextEditingController();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    super.dispose();
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Şifre gerekli';
    }
    if (value.length < 6) {
      return 'Şifre en az 6 karakter olmalı';
    }
    return null;
  }

  String? _validatePasswordConfirm(String? value) {
    if (value == null || value.isEmpty) {
      return 'Şifre tekrarı gerekli';
    }
    if (value != _passwordController.text) {
      return 'Şifreler eşleşmiyor';
    }
    return null;
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final supabase = ref.read(supabaseClientProvider);
      final userId = supabase.auth.currentUser?.id;

      if (userId == null) {
        _showErrorSnackBar('Kullanıcı bilgisi alınamadı');
        return;
      }

      await supabase.auth.updateUser(
        UserAttributes(password: _passwordController.text),
      );

      await supabase
          .from('kullanicilar')
          .update({'sifre_degisti_mi': true})
          .eq('id', userId);

      ref.invalidate(kullaniciProvider);

      final kullaniciResult = await ref.read(kullaniciProvider.future);
      if (kullaniciResult.kullaniciYuklenemedi || kullaniciResult.data == null) {
        _showErrorSnackBar(
          kullaniciResult.hataMesaji ??
              'Kullanıcı bilgileri güncellenemedi. Lütfen tekrar deneyin.',
        );
        return;
      }

      final hedef = dashboardPathForRol(kullaniciResult.data!.rol) ?? '/login';

      developer.log('şifre değiştirildi — yönlendirme = $hedef', name: _logTag);

      if (mounted) {
        context.go(hedef);
      }
    } on AuthException catch (e) {
      _showErrorSnackBar('Şifre güncelleme hatası: ${e.message}');
    } on PostgrestException catch (e) {
      developer.log(
        '[AUTH_DB_ERROR]\n'
        'code: ${e.code}\n'
        'message: ${e.message}\n'
        'details: ${e.details}\n'
        'hint: ${e.hint}',
        name: _logTag,
        level: 1000,
      );
      _showErrorSnackBar(
        'Kullanıcı bilgilerine erişilirken bir veritabanı yetki hatası oluştu.',
      );
    } catch (e) {
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
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Şifre Değiştir'),
          automaticallyImplyLeading: false,
          elevation: 0,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    const Text(
                      'Yeni Şifre Belirle',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Devam etmek için yeni bir şifre oluşturun',
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      enabled: !_isLoading,
                      decoration: InputDecoration(
                        labelText: 'Yeni Şifre',
                        hintText: '••••••••',
                        prefixIcon: const Icon(Icons.lock),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: _validatePassword,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordConfirmController,
                      obscureText: true,
                      enabled: !_isLoading,
                      decoration: InputDecoration(
                        labelText: 'Yeni Şifre Tekrar',
                        hintText: '••••••••',
                        prefixIcon: const Icon(Icons.lock),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      validator: _validatePasswordConfirm,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _handleSave,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              )
                            : const Text('Kaydet'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
