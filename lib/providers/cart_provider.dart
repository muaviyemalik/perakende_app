import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dashboard_stats_provider.dart';
import 'sales_provider.dart';

import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- 1. ÜRÜNLERİ YEREL HAFIZAYA KAYDET (İnternet Varkén Arka Planda Çalışır) ---
Future<void> cacheProductsLocally() async {
  try {
    final response = await Supabase.instance.client.from('products').select();
    final prefs = await SharedPreferences.getInstance();

    // Ürün listesini JSON string formatına çevirip telefona kaydediyoruz
    String encodedData = jsonEncode(response);
    await prefs.setString('cached_products', encodedData);
  } catch (e) {
    // İnternet yoksa veya hata olursa sessizce geç, yereldeki eski veriyi kullanmaya devam ederiz
  }
}

// --- 2. ÜRÜNLERİ GETİR (İnternet varsa buluttan al + önbellekle, yoksa telefondan oku) ---
Future<List<dynamic>> getProductsSmart() async {
  final prefs = await SharedPreferences.getInstance();

  try {
    // Önce internet bağlantısını test edelim
    final response = await Supabase.instance.client.from('products').select();

    // İnternet var! Gelen veriyi hemen yerel hafızaya da yedekleyelim (Cache)
    await prefs.setString('cached_products', jsonEncode(response));
    return response;
  } catch (e) {
    // İNTERNET YOK! Telefonun yerel hafızasındaki son kayıtlı ürünleri çekiyoruz
    String? cachedData = prefs.getString('cached_products');

    if (cachedData != null) {
      List<dynamic> decodedList = jsonDecode(cachedData);
      return decodedList;
    } else {
      // Hiç önbellek yoksa boş liste döndür
      return [];
    }
  }
}

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
  List<CartItem> build() {
    // --- OTOMATİK İNTERNET DİNLEYİCİSİ ---
    Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      // Eğer listede 'none' yoksa, yani internet varsa:
      bool hasInternet = !results.contains(ConnectivityResult.none);

      if (hasInternet) {
        // 1. Bekleyen satışları Supabase'e gönder
        await syncOfflineSales();

        // 2. İNTERNET GELDİ VE SENKRONİZASYON BİTTİ: Şimdi paneli haberdar et!
        ref.invalidate(dashboardStatsProvider);
      }
    });

    // Sepetin başlangıç durumu (boş liste)
    return [];
  }

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

  // --- ÇEVRİMDIŞI SATIŞLARI YEREL HAFIZAYA KAYDETME ---
  Future<void> _saveSaleToLocal(
      String userId, double total, List<CartItem> items) async {
    final prefs = await SharedPreferences.getInstance();

    // Satış verisini JSON formatına çeviriyoruz
    final saleData = {
      'user_id': userId,
      'total_amount': total,
      'items': items
          .map((e) => {
                'product_id': e.product_id,
                'quantity': e.quantity,
                'unit_price': e.price,
              })
          .toList(),
      'created_at': DateTime.now().toIso8601String(),
    };

    // Mevcut bekleyen satışları al
    List<String> offlineSales = prefs.getStringList('offline_sales') ?? [];
    offlineSales.add(jsonEncode(saleData));

    // Yeni listeyi telefona kaydet
    await prefs.setStringList('offline_sales', offlineSales);
  }

  // --- İNTERNET GELDİĞİNDE BEKLEYEN SATIŞLARI SUPABASE'E GÖNDERME ---
  Future<void> syncOfflineSales() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> offlineSales = prefs.getStringList('offline_sales') ?? [];

    if (offlineSales.isEmpty) return; // Bekleyen satış yoksa çık

    // İnternet var mı diye tekrar kontrol et
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) return;

    List<String> failedSales = [];

    for (String saleJson in offlineSales) {
      try {
        final saleData = jsonDecode(saleJson);
        final userId = saleData['user_id'];
        final totalAmount = saleData['total_amount'];
        final items = saleData['items'] as List<dynamic>;

        // 1. Satışı oluştur
        final saleResponse = await Supabase.instance.client
            .from('sales')
            .insert({'total_amount': totalAmount, 'created_by': userId})
            .select('id')
            .single();

        final saleId = saleResponse['id'];

        // 2. Satış detaylarını ve stokları güncelle
        for (var item in items) {
          await Supabase.instance.client.from('sale_items').insert({
            'sale_id': saleId,
            'product_id': item['product_id'],
            'quantity': item['quantity'],
            'unit_price': item['unit_price'],
          });

          // Stok düşme işlemi
          final productData = await Supabase.instance.client
              .from('products')
              .select('stock')
              .eq('id', item['product_id'])
              .single();

          int currentStock = productData['stock'];
          await Supabase.instance.client
              .from('products')
              .update({'stock': currentStock - (item['quantity'] as int)}).eq(
                  'id', item['product_id']);
        }
      } catch (e) {
        // Eğer bu satış gönderilirken hata çıkarsa, silinmemesi için hatalılar listesine al
        failedSales.add(saleJson);
      }
    }

    // Gönderilenleri temizle, sadece hata verenleri (varsa) telefonda tutmaya devam et
    await prefs.setStringList('offline_sales', failedSales);

    // TÜM SATIŞLAR BULUTA BAŞARIYLA GÖNDERİLDİKTEN SONRA:
    ref.invalidate(dashboardStatsProvider);
  }

  // --- ANA SATIŞ METODU (GÜNCELLENMİŞ) ---
  Future<String?> completeSale() async {
    if (state.isEmpty) return 'Sepet boş!';

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return 'Kullanıcı girişi bulunamadı!';

    // İNTERNET KONTROLÜ
    final connectivityResult = await Connectivity().checkConnectivity();
    bool isOffline = connectivityResult.contains(ConnectivityResult.none);

    if (isOffline) {
      // İNTERNET YOK: Satışı telefona kaydet
      await _saveSaleToLocal(userId, totalAmount, state);
      clearCart();
      return 'İnternet bağlantısı yok. Satış telefona kaydedildi, bağlantı geldiğinde sisteme aktarılacak.';
    }

    // İNTERNET VAR: Önce bekleyen eski çevrimdışı satışlar varsa onları gönder
    await syncOfflineSales();

    // SONRA ŞU ANKİ SATIŞI NORMAL ŞEKİLDE YAP
    try {
      // (Burada senin önceki stok kontrolü ve insert/update kodların çalışacak)
      // Stok Kontrolü
      for (var item in state) {
        final productData = await Supabase.instance.client
            .from('products')
            .select('stock')
            .eq('id', item.product_id)
            .single();

        int currentStock = productData['stock'];
        if (item.quantity > currentStock) {
          return 'Yetersiz stok: ${item.name} (Kalan: $currentStock)';
        }
      }

      // Satış Ekleme
      final saleResponse = await Supabase.instance.client
          .from('sales')
          .insert({'total_amount': totalAmount, 'created_by': userId})
          .select('id')
          .single();

      final saleId = saleResponse['id'];

      // Detayları Ekleme ve Stok Düşme
      for (var item in state) {
        await Supabase.instance.client.from('sale_items').insert({
          'sale_id': saleId,
          'product_id': item.product_id,
          'quantity': item.quantity,
          'unit_price': item.price,
        });

        final productData = await Supabase.instance.client
            .from('products')
            .select('stock')
            .eq('id', item.product_id)
            .single();

        int currentStock = productData['stock'];
        await Supabase.instance.client.from('products').update(
            {'stock': currentStock - item.quantity}).eq('id', item.product_id);
      }
      clearCart();
      return null; // Başarılı
    } catch (e) {
      return 'Satış sırasında hata oluştu: $e';
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
