import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/storage/local_storage_service.dart';
import 'dashboard_stats_provider.dart';

import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// ÜRÜNLERİ YEREL HAFIZAYA KAYDET (İnternet Varken Arka Planda Çalışır)
// =============================================================================
// GÜVENLİK: isletmeId parametre olarak alınır — asla LocalStorage'dan türetilmez.
// Bu değer auth oturumundan gelen kullanıcının gerçek işletmesidir.
Future<void> cacheProductsLocally(int isletmeId) async {
  try {
    // Yalnızca kullanıcının işletmesine ait ürünleri cachele
    final response = await Supabase.instance.client
        .from('products')
        .select()
        .eq('isletme_id', isletmeId); // Tenant filtresi
    final prefs = await SharedPreferences.getInstance();
    String encodedData = jsonEncode(response);
    await prefs.setString('cached_products_$isletmeId', encodedData);
  } catch (e) {
    // İnternet yoksa veya hata olursa sessizce geç
  }
}

// =============================================================================
// ÜRÜNLERİ GETİR (İnternet varsa buluttan al + önbellekle, yoksa telefondan oku)
// =============================================================================
// GÜVENLİK: isletmeId parametre olarak alınır — asla LocalStorage'dan türetilmez.
// Çevrimdışı cache, işletme bazlı key ile saklanır (çapraz işletme karışıklığı engeli).
Future<List<dynamic>> getProductsSmart(int isletmeId) async {
  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'cached_products_$isletmeId';

  try {
    // İnternet varsa: Yalnızca bu işletmenin ürünlerini çek + cachele
    final response = await Supabase.instance.client
        .from('products')
        .select()
        .eq('isletme_id', isletmeId); // Tenant filtresi

    await prefs.setString(cacheKey, jsonEncode(response));
    return response;
  } catch (e) {
    // İnternet yok: Bu işletmeye ait yerel cache'den oku
    final cachedData = prefs.getString(cacheKey);
    if (cachedData != null) {
      return jsonDecode(cachedData) as List<dynamic>;
    }
    return [];
  }
}

// =============================================================================
// CartItem Model
// =============================================================================
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

// =============================================================================
// CartNotifier
// =============================================================================
class CartNotifier extends Notifier<List<CartItem>> {
  @override
  List<CartItem> build() {
    // Otomatik internet dinleyicisi — bağlantı gelince çevrimdışı satışları senkronize et
    Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      bool hasInternet = !results.contains(ConnectivityResult.none);

      if (hasInternet) {
        await syncOfflineSales();
        ref.invalidate(dashboardStatsProvider);
      }
    });

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

  // ---------------------------------------------------------------------------
  // ÇEVRİMDIŞI SATIŞ KAYDETME
  // ---------------------------------------------------------------------------
  // GÜVENLİK NOTU:
  //   isletmeId burada parametre olarak alınır. Bu değer çağıran tarafından
  //   auth oturumundan türetilmiş olmalıdır (LocalStorage'dan değil).
  //   Supabase'e gönderildiğinde RLS ve trigger, isletme_id'yi sunucu
  //   tarafında doğrulayacak ve override edecektir.
  Future<void> _saveSaleToLocal(
      String userId, int isletmeId, double total, List<CartItem> items) async {
    final prefs = await SharedPreferences.getInstance();

    final saleData = {
      'user_id': userId,
      'isletme_id': isletmeId, // Auth oturumundan gelen değer
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

    List<String> offlineSales = prefs.getStringList('offline_sales') ?? [];
    offlineSales.add(jsonEncode(saleData));
    await prefs.setStringList('offline_sales', offlineSales);
  }

  // ---------------------------------------------------------------------------
  // İNTERNET GELDİĞİNDE BEKLEYEN SATIŞLARI SUPABASE'E GÖNDER
  // ---------------------------------------------------------------------------
  // GÜVENLİK NOTU:
  //   Çevrimdışı kayıtlardaki isletme_id değeri referans olarak kullanılır
  //   ancak Supabase sunucusundaki TRIGGER bu değeri her durumda
  //   kullanıcının gerçek işletmesiyle override eder.
  //   Yani manipüle edilmiş bir offline kayıt gönderse bile RLS reddeder.
  Future<void> syncOfflineSales() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> offlineSales = prefs.getStringList('offline_sales') ?? [];

    if (offlineSales.isEmpty) return;

    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) return;

    List<String> failedSales = [];

    for (String saleJson in offlineSales) {
      try {
        final saleData = jsonDecode(saleJson);
        final userId = saleData['user_id'] as String?;
        final totalAmount = saleData['total_amount'];
        final items = saleData['items'] as List<dynamic>;
        final isletmeId = saleData['isletme_id'];

        if (isletmeId == null || userId == null) {
          failedSales.add(saleJson);
          continue;
        }

        // Satışı oluştur
        // NOT: Sunucu tarafındaki trigger isletme_id ve created_by'ı override eder.
        final saleResponse = await Supabase.instance.client
            .from('sales')
            .insert({
              'total_amount': totalAmount,
              'created_by': userId,
              'isletme_id': isletmeId,
            })
            .select('id')
            .single();

        final saleId = saleResponse['id'];

        // Satış kalemlerini ve stokları güncelle
        for (var item in items) {
          // sale_items INSERT: trigger isletme_id'yi sales tablosundan alır
          await Supabase.instance.client.from('sale_items').insert({
            'sale_id': saleId,
            'product_id': item['product_id'],
            'quantity': item['quantity'],
            'unit_price': item['unit_price'],
            'isletme_id': isletmeId, // Trigger override edecek (güvenlik katmanı DB'de)
          });

          // Stok güncelleme: RLS, kendi işletmesi dışındaki ürünleri engeller
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
        failedSales.add(saleJson);
      }
    }

    await prefs.setStringList('offline_sales', failedSales);
    ref.invalidate(dashboardStatsProvider);
  }

  // ---------------------------------------------------------------------------
  // ANA SATIŞ METODU
  // ---------------------------------------------------------------------------
  // GÜVENLİK NOTU:
  //   isletme_id, auth oturumundan türetilmiş kullaniciProvider üzerinden alınır.
  //   LocalStorage'a güvenilmez — sadece performans için tutulur.
  //   Supabase RLS + trigger her INSERT'te sunucu tarafında doğrulama yapar.
  Future<String?> completeSale() async {
    if (state.isEmpty) return 'Sepet boş!';

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return 'Kullanıcı girişi bulunamadı!';

    // İnternet kontrolü
    final connectivityResult = await Connectivity().checkConnectivity();
    final bool isOffline = connectivityResult.contains(ConnectivityResult.none);

    if (isOffline) {
      // Çevrimdışı mod: isletme_id'yi LocalStorage'dan al
      // (Çevrimdışıyken Supabase'e ulaşamayız — yerel cache kullanmak zorundayız.)
      // Güvenlik notu: Supabase'e gönderildiğinde RLS + trigger doğrulayacak.
      final isletmeId = await LocalStorageService.getIsletmeId();
      if (isletmeId == null) {
        return 'İşletme bilgisi bulunamadı. Lütfen tekrar giriş yapın.';
      }

      await _saveSaleToLocal(userId, isletmeId, totalAmount, state);
      clearCart();
      return 'İnternet bağlantısı yok. Satış telefona kaydedildi, '
          'bağlantı geldiğinde sisteme aktarılacak.';
    }

    // Çevrimiçi mod: Önce bekleyen çevrimdışı satışları gönder
    await syncOfflineSales();

    try {
      // İşletme ID'sini Supabase'den doğrudan oku (auth → kullanicilar tablosu)
      // Bu sorgu RLS korumalıdır — sadece kendi kaydı döner.
      final kullaniciRow = await client
          .from('kullanicilar')
          .select('isletme_id')
          .eq('id', userId)
          .single();

      final isletmeId = kullaniciRow['isletme_id'] as int?;
      if (isletmeId == null) {
        return 'İşletme bilgisi bulunamadı. Lütfen tekrar giriş yapın.';
      }

      // Stok kontrolü — RLS kendi işletmesi dışındaki ürünleri zaten engelliyor
      for (var item in state) {
        final productData = await client
            .from('products')
            .select('stock')
            .eq('id', item.product_id)
            .single();

        int currentStock = productData['stock'];
        if (item.quantity > currentStock) {
          return 'Yetersiz stok: ${item.name} (Kalan: $currentStock)';
        }
      }

      // Satışı oluştur
      // NOT: Sunucu TRIGGER isletme_id'yi ve created_by'ı override eder.
      final saleResponse = await client
          .from('sales')
          .insert({
            'total_amount': totalAmount,
            'created_by': userId, // Trigger override edecek
            'isletme_id': isletmeId, // Trigger override edecek
          })
          .select('id')
          .single();

      final saleId = saleResponse['id'];

      // Satış kalemlerini ekle ve stokları düş
      for (var item in state) {
        // sale_items INSERT: trigger isletme_id'yi sales tablosundan çeker
        await client.from('sale_items').insert({
          'sale_id': saleId,
          'product_id': item.product_id,
          'quantity': item.quantity,
          'unit_price': item.price,
          'isletme_id': isletmeId, // Trigger override edecek (DB güvenliği)
        });

        final productData = await client
            .from('products')
            .select('stock')
            .eq('id', item.product_id)
            .single();

        int currentStock = productData['stock'];
        await client
            .from('products')
            .update({'stock': currentStock - item.quantity}).eq(
                'id', item.product_id);
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
