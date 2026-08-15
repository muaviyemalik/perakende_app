import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers/tenant_provider.dart';

/// Satış geçmişini giriş yapan kullanıcının işletmesiyle filtreli getirir.
///
/// GÜVENLİK: isletme_id filtresi uygulanır. Supabase RLS asıl güvenlik katmanıdır.
/// Başka işletmenin sale UUID'sini bilen biri bu sorgudan hiçbir şey alamaz.
final salesHistoryProvider =
    FutureProvider<List<dynamic>>((ref) async {
  final isletmeId = await ref.watch(currentIsletmeIdProvider.future);

  if (isletmeId == null) return [];

  final response = await Supabase.instance.client
      .from('sales')
      .select('*, sale_items(*, products(*))')
      .eq('isletme_id', isletmeId) // Tenant filtresi — Flutter UX katmanı
      .order('created_at', ascending: false);

  return response as List<dynamic>;
});
