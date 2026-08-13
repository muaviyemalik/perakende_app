import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final dashboardStatsProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final supabase = Supabase.instance.client;

  final productsResponse =
      await supabase.from('products').select('id, name, stock');
  final salesResponse =
      await supabase.from('sales').select('*, profiles!created_by(email)');

  final products = List<Map<String, dynamic>>.from(
    (productsResponse as List?)
            ?.map((item) => Map<String, dynamic>.from(item)) ??
        const [],
  );
  final sales = List<Map<String, dynamic>>.from(
    (salesResponse as List?)?.map((item) => Map<String, dynamic>.from(item)) ??
        const [],
  );

  final totalProducts = products.length;

  final criticalProducts = products.where((product) {
    final stock = product['stock'];
    if (stock is int) return stock < 10;
    if (stock is num) return stock < 10;
    return false;
  }).toList();

  final criticalStock = criticalProducts.length;

  final criticalProductsList = criticalProducts
      .map((product) => {
            'name': product['name'] ?? 'Bilinmeyen Ürün',
            'stock': product['stock'] ?? 0,
          })
      .toList();

  final now = DateTime.now();
  final startOfDay = DateTime(now.year, now.month, now.day);
  final endOfDay = DateTime(now.year, now.month, now.day + 1);

  double dailyRevenue = 0.0;
  final employeeTotals = <String, double>{};

  for (final sale in sales) {
    final totalAmountValue = sale['total_amount'];
    final totalAmount =
        totalAmountValue is num ? totalAmountValue.toDouble() : 0.0;

    final createdAtValue = sale['created_at'];
    if (createdAtValue is String) {
      final saleDate = DateTime.tryParse(createdAtValue);
      if (saleDate != null &&
          !saleDate.isBefore(startOfDay) &&
          saleDate.isBefore(endOfDay)) {
        dailyRevenue += totalAmount;
      }
    }

    final profile = sale['profiles'];
    final email = profile is Map
        ? (profile['email'] ?? 'Bilinmeyen satıcı')
        : 'Bilinmeyen satıcı';

    employeeTotals[email.toString()] =
        (employeeTotals[email.toString()] ?? 0.0) + totalAmount;
  }

  final employeeSales = employeeTotals.entries
      .map((entry) => {'email': entry.key, 'total': entry.value})
      .toList()
    ..sort((a, b) => (b['total'] as num).compareTo(a['total'] as num));

  return {
    'totalProducts': totalProducts,
    'criticalStock': criticalStock,
    'criticalProductsList': criticalProductsList,
    'dailyRevenue': dailyRevenue,
    'employeeSales': employeeSales,
  };
});
