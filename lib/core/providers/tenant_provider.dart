import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/providers/auth_provider.dart';

/// Giriş yapan kullanıcının işletme ID'sini döndürür.
///
/// GÜVENLİK NOTU:
///   Bu provider, isletme_id bilgisini LocalStorage'dan ALMAZ.
///   auth.uid() → kullanicilar.id → kullanicilar.isletme_id zincirini
///   Supabase üzerinden okur. Böylece:
///   - LocalStorage manipülasyonu etkisiz kalır.
///   - Gerçek güvenlik katmanı Supabase RLS tarafındadır.
///   - Bu provider yalnızca Flutter tarafı filtreleme/UX için kullanılır.
///
/// Kullanım:
///   final isletmeId = await ref.watch(currentIsletmeIdProvider.future);
final currentIsletmeIdProvider = FutureProvider<int?>((ref) async {
  final result = await ref.watch(kullaniciProvider.future);
  return result.data?.isletmeId;
});
