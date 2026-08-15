import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers/tenant_provider.dart';

/// Barkod ile ürün arar — yalnızca giriş yapan kullanıcının işletmesinde.
///
/// GÜVENLİK: isletme_id filtresi uygulanır. RLS de bunu garanti eder.
/// Başka işletmenin barkodunu bilen biri kendi işletmesinde sonuç alamaz.
final productByBarcodeProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, barcode) async {
  final isletmeId = await ref.watch(currentIsletmeIdProvider.future);

  if (isletmeId == null) return null;

  final response = await Supabase.instance.client
      .from('products')
      .select()
      .eq('barcode', barcode)
      .eq('isletme_id', isletmeId) // Tenant filtresi — Flutter UX katmanı
      .maybeSingle();

  return response;
});

/// Tüm ürünleri listeler — yalnızca giriş yapan kullanıcının işletmesinde.
///
/// GÜVENLİK: isletme_id filtresi uygulanır. Supabase RLS asıl güvenlik katmanıdır.
final allProductsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final isletmeId = await ref.watch(currentIsletmeIdProvider.future);

  if (isletmeId == null) return [];

  final response = await Supabase.instance.client
      .from('products')
      .select()
      .eq('isletme_id', isletmeId) // Tenant filtresi — Flutter UX katmanı
      .order('name');

  return List<Map<String, dynamic>>.from(response);
});
