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
        final items = saleData['items'] as List<dynamic>;

        // Satışı RPC üzerinden atomik olarak gerçekleştir
        final rpcItems = items.map((item) => {
              'product_id': item['product_id'],
              'quantity': item['quantity'],
            }).toList();

        await Supabase.instance.client.rpc('complete_sale', params: {
          'p_items': rpcItems,
        });
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
  //   Online satış complete_sale RPC üzerinden atomik olarak gerçekleşir.
  //   isletme_id, created_by, unit_price ve total_amount DB tarafında belirlenir.
  //   Client manipülasyonu imkânsız kılınmıştır.
  //   Offline satış P1'de ayrıca ele alınacak.
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
      // -----------------------------------------------------------------------
      // P0.2: Tek atomik RPC çağrısı — complete_sale
      //
      // GÜVENLİK:
      //   • isletme_id ve created_by DB tarafında auth.uid() ile belirlenir.
      //   • unit_price her zaman products.price'tan alınır (client fiyatına güvenilmez).
      //   • total_amount DB hesaplar (client manipülasyonuna kapalı).
      //   • Stok kontrolü, sales/sale_items INSERT ve stok güncelleme tek
      //     transaction içinde gerçekleşir — kısmen başarı imkânsız.
      //   • FOR UPDATE ORDER BY id kilidi ile race condition koruması sağlanır.
      //
      // PARAMETRELER:
      //   p_items: [{product_id: uuid, quantity: int}] — sadece ürün kimliği ve adet.
      //   Fiyat, tenant, kullanıcı bilgileri sunucudan alınır.
      // -----------------------------------------------------------------------
      final items = state
          .map((item) => {
                'product_id': item.product_id,
                'quantity': item.quantity,
              })
          .toList();

      await client.rpc('complete_sale', params: {'p_items': items});

      clearCart();
      return null; // Başarılı
    } on PostgrestException catch (e) {
      // DB fonksiyonu SATIS_HATA:* prefix'li mesajlar fırlatır
      final msg = e.message;
      if (msg.contains('SATIS_HATA:YETERSIZ_STOK')) {
        // DETAIL alanından ürün adını çıkar
        final detail = e.details?.toString() ?? '';
        final urunMatch = RegExp(r'urun=([^,]+)').firstMatch(detail);
        final mevcutMatch = RegExp(r'mevcut=(\d+)').firstMatch(detail);
        final urunAdi = urunMatch?.group(1) ?? 'Ürün';
        final mevcut = mevcutMatch?.group(1) ?? '0';
        return 'Yetersiz stok: $urunAdi (Kalan: $mevcut)';
      }
      if (msg.contains('SATIS_HATA:SEPET_BOS')) {
        return 'Sepet boş!';
      }
      if (msg.contains('SATIS_HATA:GECERSIZ_MIKTAR')) {
        return 'Geçersiz miktar — adet 0 veya negatif olamaz.';
      }
      if (msg.contains('SATIS_HATA:TEKRAR_URUN_ID')) {
        return 'Sepette tekrar eden ürün var. Lütfen sepeti kontrol edin.';
      }
      if (msg.contains('SATIS_HATA:GECERSIZ_URUN')) {
        return 'Geçersiz ürün — bu işletmeye ait olmayan ürün seçildi.';
      }
      if (msg.contains('SATIS_HATA:ISLETME_BULUNAMADI') ||
          msg.contains('SATIS_HATA:KIMLIK_DOGRULANAMADI')) {
        return 'Oturum bilgisi geçersiz. Lütfen tekrar giriş yapın.';
      }
      return 'Satış sırasında hata oluştu: ${e.message}';
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
