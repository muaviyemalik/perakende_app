import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/offline_sale_queue.dart';
import '../core/providers/tenant_provider.dart';
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
    // Otomatik internet dinleyicisi — bağlantı gelince çevrimdışı satışları senkronize et.
    // Provider her yeniden kurulduğunda (ör. çıkışta invalidate) eski dinleyici
    // iptal edilir; aksi halde dinleyiciler birikir ve aynı sync defalarca tetiklenir.
    final subscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      bool hasInternet = !results.contains(ConnectivityResult.none);

      if (hasInternet) {
        final synced = await _queue.syncAll(
          currentScope: await _currentSaleScope(),
        );
        if (synced > 0) {
          ref.invalidate(dashboardStatsProvider);
        }
      }
    });
    ref.onDispose(subscription.cancel);

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
    // Sepet temizlendi: sonraki satış yeni bir satıştır, yeni anahtar alır.
    _pendingKey = null;
    _pendingSignature = null;
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
    // Çift dokunma: aynı anda ikinci bir satış çağrısı başlatılmaz.
    if (_saleInFlight) return 'Satış işleniyor, lütfen bekleyin.';
    _saleInFlight = true;
    try {
      return await _completeSale();
    } finally {
      _saleInFlight = false;
    }
  }

  bool _saleInFlight = false;
  String? _pendingKey;
  String? _pendingSignature;

  /// Aynı kullanıcı + aynı sepet içeriği için hep AYNI anahtarı döndürür.
  /// Anahtar yalnızca sepet temizlendiğinde (satış sonuçlandığında) sıfırlanır.
  /// Böylece kuyruğa yazma bile başarısız olsa, kasiyerin tekrar denemesi
  /// sunucuya aynı anahtarla gider ve ikinci satış oluşmaz.
  String _keyFor(String userId, List<Map<String, dynamic>> items) {
    final signature = '$userId|${jsonEncode(items)}';
    if (signature != _pendingSignature || _pendingKey == null) {
      _pendingSignature = signature;
      _pendingKey = _queue.generateKey();
    }
    return _pendingKey!;
  }

  Future<String?> _completeSale() async {
    if (state.isEmpty) return 'Sepet boş!';

    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return 'Kullanıcı girişi bulunamadı!';

    final scope = await _currentSaleScope();
    if (scope == null || scope.userId != userId) {
      return 'Oturum veya işletme bilgisi doğrulanamadı. '
          'Lütfen tekrar giriş yapın.';
    }

    // Sepet verilerini RPC formatına çevir — sadece product_id ve quantity.
    // Fiyat, tenant, kullanıcı bilgileri sunucudan alınır.
    final items = state
        .map((item) => {
              'product_id': item.product_id,
              'quantity': item.quantity,
            })
        .toList();

    // Anahtar denemeden ÖNCE belirlenir ve aynı sepet için tekrar kullanılır.
    // (Eskiden her "tekrar dene"de yeni anahtar üretiliyordu ve yanıtı
    // kaybolan satış ikinci kez kaydedilebiliyordu.)
    final idempotencyKey = _keyFor(userId, items);

    // İnternet kontrolü
    final connectivityResult = await Connectivity().checkConnectivity();
    final bool isOffline = connectivityResult.contains(ConnectivityResult.none);

    if (isOffline) {
      // Çevrimdışı mod: OfflineSaleQueue'ya ekle
      // Güvenlik notu: Queue owner scope'u replay öncesi aktif oturumla
      // eşleşmelidir. Satışın authoritative isletme_id, created_by ve fiyat
      // bilgileri yine DB tarafında belirlenir.
      try {
        await _queue.enqueue(
          idempotencyKey: idempotencyKey,
          items: items,
          scope: scope,
        );
      } catch (_) {
        return 'İnternet bağlantısı yok ve satış telefona kaydedilemedi. '
            'Sepet korunuyor, lütfen tekrar deneyin.';
      }
      clearCart();
      return 'İnternet bağlantısı yok. Satış telefona kaydedildi, '
          'bağlantı geldiğinde sisteme aktarılacak.';
    }

    // Çevrimiçi mod: Önce bekleyen çevrimdışı satışları senkronize et
    final synced = await _queue.syncAll(currentScope: scope);
    if (synced > 0) {
      ref.invalidate(dashboardStatsProvider);
    }

    // Sync beklenirken oturum değiştiyse eski sepeti yeni kasiyer adına
    // gönderme — sunucu satışı o anki kullanıcıya yazar.
    if (client.auth.currentUser?.id != scope.userId) {
      return 'Oturum değişti. Lütfen tekrar giriş yapın.';
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
      if (msg.contains('SATIS_HATA:')) {
        // Sunucu satışı açıkça reddetti; işlem geri alındı, sepet korunur.
        return 'Satış sırasında hata oluştu: ${e.message}';
      }
      if (OfflineSaleQueue.isAlreadyProcessedError(e)) {
        // Aynı anahtarla eşzamanlı bir çağrı satışı zaten kaydetmiş.
        clearCart();
        ref.invalidate(dashboardStatsProvider);
        return null;
      }
      // Satış kuralı dışı bir hata (ağ geçidi, oturum süresi vb.):
      // satışın kaydedilip kaydedilmediği bilinemez.
      return _queueUnknownOutcome(idempotencyKey, items, scope);
    } catch (e) {
      // Ağ hatası / zaman aşımı: istek sunucuya ulaşıp satış kaydedilmiş,
      // yalnızca yanıt kaybolmuş olabilir.
      return _queueUnknownOutcome(idempotencyKey, items, scope);
    }
  }

  /// Sonucu belirsiz satışı aynı anahtarla kuyruğa alır ve sepeti temizler.
  /// Kasiyerin "tekrar dene" ile ikinci satış oluşturmasını engeller.
  Future<String> _queueUnknownOutcome(
    String idempotencyKey,
    List<Map<String, dynamic>> items,
    OfflineSaleScope scope,
  ) async {
    try {
      await _queue.enqueue(
        idempotencyKey: idempotencyKey,
        items: items,
        scope: scope,
      );
    } catch (_) {
      // Kuyruğa da yazılamadı: sepet ve anahtar korunur. Tekrar denemek
      // güvenlidir — aynı anahtarla gider, sunucu iki kez kaydetmez.
      return 'Satışın sonucu doğrulanamadı ve telefona kaydedilemedi. '
          'Sepet korunuyor; tekrar denediğinizde aynı satış olarak '
          'gönderilecek, iki kez kaydedilmez.';
    }
    clearCart();
    return 'Bağlantı sorunu nedeniyle satışın sonucu doğrulanamadı. '
        'Satış telefona kaydedildi ve bağlantı gelince aynı kimlikle '
        'gönderilecek; iki kez kaydedilmez. Tekrar satış yapmayın.';
  }

  Future<OfflineSaleScope?> _currentSaleScope() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) return null;

    try {
      final isletmeId = await ref.read(currentIsletmeIdProvider.future);
      if (isletmeId == null || isletmeId <= 0) return null;
      return OfflineSaleScope(userId: userId, isletmeId: isletmeId);
    } catch (_) {
      return null;
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
