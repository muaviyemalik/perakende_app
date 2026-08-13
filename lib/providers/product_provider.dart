import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final productByBarcodeProvider =
    FutureProvider.family<Map<String, dynamic>?, String>((ref, barcode) async {
  final response = await Supabase.instance.client
      .from('products')
      .select()
      .eq('barcode', barcode)
      .maybeSingle();

  return response;
});
