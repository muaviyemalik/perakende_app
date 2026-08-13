import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final salesHistoryProvider = FutureProvider<List<dynamic>>((ref) async {
  final response = await Supabase.instance.client
      .from('sales')
      .select('*, sale_items(*, products(*)), profiles!created_by(email)')
      .order('created_at', ascending: false);

  return response as List<dynamic>;
});
