import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/offline_sale_queue.dart';
import 'dashboard_stats_provider.dart';


// =============================================================================
// CartItem Model
// =============================================================================
class CartItem {
  // ignore: non_constant_identifier_names
  final String product_id;
  final String name;
  final double price;
  final int quantity;
  final int stock;

  const CartItem({
    required this.product_id,
    required this.name,
    required this.price,
    required this.quantity,
    required this.stock,
  });

  CartItem copyWith({
    // ignore: non_constant_identifier_names
    String? product_id,
    String? name,
    double? price,
    int? quantity,
    int? stock,
  }) {
    return CartItem(
      product_id: product_id ?? this.product_id,
      name: name ?? this.name,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
      stock: stock ?? this.stock,
    );
  }

  double get lineTotal => price * quantity;
}

// =============================================================================
// CartNotifier
// =============================================================================
class CartNotifier extends Notifier<List<CartItem>> {
  final _queue = OfflineSaleQueue.instance;

  @override
  List<CartItem> build() {
    // Otomatik internet dinleyicisi — bağlantı gelince çevrimdışı satışları senkronize et
    Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      bool hasInternet = !results.contains(ConnectivityResult.none);

      if (hasInternet) {
        final synced = await _queue.syncAll();
        if (synced > 0) {
          ref.invalidate(dashboardStatsProvider);
        }
      }
    });

    return [];
  }

  String? addToCart({
    required String productId,
    required String name,
    required double price,
    required int stock,
    int quantity = 1,
  }) {
    if (stock <= 0) {
      return 'Bu ürün stokta yok.';
    }

    final existingIndex =
        state.indexWhere((item) => item.product_id == productId);

    if (existingIndex != -1) {
      final existingItem = state[existingIndex];
      final newQuantity = existingItem.quantity + quantity;
      
      if (newQuantity > stock) {
        return 'Stokta yalnızca $stock adet bulunuyor.';
      }

      state = [
        ...state.sublist(0, existingIndex),
        existingItem.copyWith(quantity: newQuantity),
        ...state.sublist(existingIndex + 1),
      ];
      return null;
    }

    if (quantity > stock) {
      return 'Stokta yalnızca $stock adet bulunuyor.';
    }

    state = [
      ...state,
      CartItem(
        product_id: productId,
        name: name,
        price: price,
        quantity: quantity,
        stock: stock,
      ),
    ];
    return null;
  }

  String? updateQuantity(String productId, {required int delta}) {
    String? errorMessage;
    
    final updatedItems = state
        .map((item) {
          if (item.product_id != productId) {
            return item;
          }

          final nextQuantity = item.quantity + delta;
          if (nextQuantity <= 0) {
            return null;
          }
          
          if (nextQuantity > item.stock) {
            errorMessage = 'Stokta yalnızca ${item.stock} adet bulunuyor.';
            return item; // Değişiklik yapma, eski item'ı dön
          }

          return item.copyWith(quantity: nextQuantity);
        })
        .whereType<CartItem>()
        .toList();

    if (errorMessage == null) {
      state = updatedItems;
    }
    
    return errorMessage;
  }

  void removeItem(String productId) {
    state = state.where((item) => item.product_id != productId).toList();
  }

  void clearCart() {
    state = [];
  }

  // ---------------------------------------------------------------------------
  // ANA SATIŞ METODU
  // ---------------------------------------------------------------------------
  // GÜVENLİK NOTU:
  //   Online satış complete_sale RPC üzerinden atomik olarak gerçekleşir.
  //   isletme_id, created_by, unit_price ve total_amount DB tarafında belirlenir.
  //   Client manipülasyonu imkânsız kılınmıştır.
  //
  // IDEMPOTENCY:
  //   Her satışa (online veya offline) UUID v4 idempotency key atanır.
  //   DB tarafındaki UNIQUE(idempotency_key) ile tekrar gönderim koruması sağlanır.
  //
  // ÇEVRİMDIŞI:
  //   İnternet yoksa satış OfflineSaleQueue'ya eklenir. Bağlantı geldiğinde
  //   connectivity listener otomatik olarak syncAll() tetikler.
  Future<String?> completeSale() async {
    if (state.isEmpty) return 'Sepet boş!';

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return 'Kullanıcı girişi bulunamadı!';

    // Sepet verilerini RPC formatına çevir — sadece product_id ve quantity.
    // Fiyat, tenant, kullanıcı bilgileri sunucudan alınır.
    final items = state
        .map((item) => {
              'product_id': item.product_id,
              'quantity': item.quantity,
            })
        .toList();

    // İnternet kontrolü
    final connectivityResult = await Connectivity().checkConnectivity();
    final bool isOffline = connectivityResult.contains(ConnectivityResult.none);

    if (isOffline) {
      // Çevrimdışı mod: OfflineSaleQueue'ya ekle
      // Güvenlik notu: Supabase'e gönderildiğinde RLS + trigger doğrulayacak.
      // isletme_id, created_by ve fiyat bilgileri DB tarafında belirlenecek.
      await _queue.enqueue(
        idempotencyKey: _queue.generateKey(),
        items: items,
      );
      clearCart();
      return 'İnternet bağlantısı yok. Satış telefona kaydedildi, '
          'bağlantı geldiğinde sisteme aktarılacak.';
    }

    // Çevrimiçi mod: Önce bekleyen çevrimdışı satışları senkronize et
    final synced = await _queue.syncAll();
    if (synced > 0) {
      ref.invalidate(dashboardStatsProvider);
    }

    try {
      // -----------------------------------------------------------------------
      // Tek atomik RPC çağrısı — complete_sale
      //
      // GÜVENLİK:
      //   • isletme_id ve created_by DB tarafında auth.uid() ile belirlenir.
      //   • unit_price her zaman products.price'tan alınır (client fiyatına güvenilmez).
      //   • total_amount DB hesaplar (client manipülasyonuna kapalı).
      //   • Stok kontrolü, sales/sale_items INSERT ve stok güncelleme tek
      //     transaction içinde gerçekleşir — kısmen başarı imkânsız.
      //   • FOR UPDATE ORDER BY id kilidi ile race condition koruması sağlanır.
      //
      // IDEMPOTENCY:
      //   • p_idempotency_key: UUID v4 — tekrar gönderim koruması.
      //   • DB'de UNIQUE constraint. Duplicate key gelirse mevcut satış döndürülür.
      // -----------------------------------------------------------------------
      final idempotencyKey = _queue.generateKey();

      await client.rpc('complete_sale', params: {
        'p_items': items,
        'p_idempotency_key': idempotencyKey,
      });

      clearCart();
      ref.invalidate(dashboardStatsProvider);
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
