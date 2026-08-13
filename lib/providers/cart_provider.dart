import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dashboard_stats_provider.dart';
import 'sales_provider.dart';

class CartItem {
  // ignore: non_constant_identifier_names
  final String product_id;
  final String name;
  final double price;
  final int quantity;

  const CartItem({
    required this.product_id,
    required this.name,
    required this.price,
    required this.quantity,
  });

  CartItem copyWith({
    // ignore: non_constant_identifier_names
    String? product_id,
    String? name,
    double? price,
    int? quantity,
  }) {
    return CartItem(
      product_id: product_id ?? this.product_id,
      name: name ?? this.name,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
    );
  }

  double get lineTotal => price * quantity;
}

class CartNotifier extends Notifier<List<CartItem>> {
  @override
  List<CartItem> build() => [];

  void addToCart({
    required String productId,
    required String name,
    required double price,
  }) {
    final existingIndex =
        state.indexWhere((item) => item.product_id == productId);

    if (existingIndex != -1) {
      final existingItem = state[existingIndex];
      state = [
        ...state.sublist(0, existingIndex),
        existingItem.copyWith(quantity: existingItem.quantity + 1),
        ...state.sublist(existingIndex + 1),
      ];
      return;
    }

    state = [
      ...state,
      CartItem(
        product_id: productId,
        name: name,
        price: price,
        quantity: 1,
      ),
    ];
  }

  void updateQuantity(String productId, {required int delta}) {
    final updatedItems = state
        .map((item) {
          if (item.product_id != productId) {
            return item;
          }

          final nextQuantity = item.quantity + delta;
          if (nextQuantity <= 0) {
            return null;
          }

          return item.copyWith(quantity: nextQuantity);
        })
        .whereType<CartItem>()
        .toList();

    state = updatedItems;
  }

  void removeItem(String productId) {
    state = state.where((item) => item.product_id != productId).toList();
  }

  void clearCart() {
    state = [];
  }

  Future<String?> completeSale() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        return 'Kullanıcı oturum açmamış.';
      }

      // STOK KONTROLÜ: Satışı onaylamadan ÖNCE tüm ürünlerin stoğunu kontrol et
      for (final item in state) {
        final productResponse = await Supabase.instance.client
            .from('products')
            .select('stock, name')
            .eq('id', item.product_id)
            .maybeSingle();

        if (productResponse == null) {
          return 'Ürün bulunamadı: ${item.name}';
        }

        final currentStock = productResponse['stock'] as int;
        if (item.quantity > currentStock) {
          return 'Yetersiz stok: ${item.name} (Kalan: $currentStock)';
        }
      }

      // Stok kontrolü başarılıysa satış işlemini gerçekleştir
      final saleResponse = await Supabase.instance.client
          .from('sales')
          .insert({
            'total_amount': totalAmount,
            'created_by': userId,
          })
          .select('id')
          .single();

      final saleId = saleResponse['id'];

      for (final item in state) {
        await Supabase.instance.client.from('sale_items').insert({
          'sale_id': saleId,
          'product_id': item.product_id,
          'quantity': item.quantity,
          'unit_price': item.price,
        });

        final productResponse = await Supabase.instance.client
            .from('products')
            .select('stock')
            .eq('id', item.product_id)
            .single();

        final currentStock = productResponse['stock'] as int;
        final newStock = currentStock - item.quantity;

        await Supabase.instance.client
            .from('products')
            .update({'stock': newStock}).eq('id', item.product_id);
      }

      clearCart();

      // Provider'ları invalidate et (verileri güncelle)
      ref.invalidate(dashboardStatsProvider);
      ref.invalidate(salesHistoryProvider);

      return null; // null = başarılı
    } catch (e) {
      return 'Satış işlemi başarısız oldu: $e';
    }
  }

  double get totalAmount => state.fold(
        0.0,
        (previousValue, item) => previousValue + item.lineTotal,
      );
}

final cartProvider = NotifierProvider<CartNotifier, List<CartItem>>(
  CartNotifier.new,
);
