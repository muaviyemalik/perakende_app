import 'dart:convert';
import 'dart:developer' as developer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

// =============================================================================
// OfflineSaleQueue — Çevrimdışı satış kuyruk yöneticisi
// =============================================================================
//
// AMAÇ:
//   İnternet yokken yapılan satışları SharedPreferences üzerinde güvenli bir
//   kuyrukta saklar, bağlantı geldiğinde sırayla Supabase'e gönderir.
//
// IDEMPOTENCY:
//   Her satışa Flutter tarafında UUID v4 ile benzersiz bir idempotency_key
//   atanır. complete_sale RPC bu key'i sales tablosunda UNIQUE olarak saklar.
//   Aynı key ile ikinci çağrı yapılırsa DB mevcut sale'i döndürür, tekrar
//   stok düşmez, tekrar kayıt oluşmaz.
//
// EŞZAMANLILIK:
//   _isSyncing flag ile aynı anda iki sync döngüsü çalışması engellenir.
//   Connectivity listener + manuel completeSale() aynı anda tetiklenirse
//   ikincisi sessizce atlanır.
//
// KALICI HATA YÖNETİMİ:
//   - Geçici hatalar (ağ hatası): retry_count artırılır, kuyrukta kalır
//   - Kalıcı hatalar (GECERSIZ_URUN, ISLETME_BULUNAMADI vb.): anında dead letter'a
//   - 3 başarısız deneme sonrası: dead letter kuyruğuna taşınır
// =============================================================================

const _logTag = 'OFFLINE_QUEUE';
const _pendingKey = 'offline_sale_queue';
const _deadLetterKey = 'offline_sale_dead_letters';
const _maxRetries = 3;

/// Kuyruğa alınan tek bir satış kaydı.
class QueuedSale {
  QueuedSale({
    required this.idempotencyKey,
    required this.items,
    required this.createdAt,
    this.retryCount = 0,
    this.lastError,
  });

  final String idempotencyKey;
  final List<Map<String, dynamic>> items;
  final String createdAt;
  int retryCount;
  String? lastError;

  Map<String, dynamic> toJson() => {
        'idempotency_key': idempotencyKey,
        'items': items,
        'created_at': createdAt,
        'retry_count': retryCount,
        'last_error': lastError,
      };

  factory QueuedSale.fromJson(Map<String, dynamic> json) {
    return QueuedSale(
      idempotencyKey: json['idempotency_key'] as String,
      items: (json['items'] as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      createdAt: json['created_at'] as String,
      retryCount: (json['retry_count'] as int?) ?? 0,
      lastError: json['last_error'] as String?,
    );
  }
}

class OfflineSaleQueue {
  OfflineSaleQueue._();
  static final OfflineSaleQueue instance = OfflineSaleQueue._();

  static const _uuid = Uuid();
  bool _isSyncing = false;

  // ---------------------------------------------------------------------------
  // PUBLIC API
  // ---------------------------------------------------------------------------

  /// Yeni idempotency key üretir (UUID v4).
  /// Online satışlar için de kullanılır — her satışın benzersiz kimliği olur.
  String generateKey() => _uuid.v4();

  /// Satışı kuyruğa ekler. Sepetteki ürünlerden yalnızca product_id ve
  /// quantity saklanır — fiyat ve tenant bilgisi DB tarafında belirlenir.
  Future<void> enqueue({
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
  }) async {
    final sale = QueuedSale(
      idempotencyKey: idempotencyKey,
      items: items,
      createdAt: DateTime.now().toIso8601String(),
    );

    final queue = await _loadQueue();
    queue.add(sale);
    await _saveQueue(queue);

    developer.log(
      'satış kuyruğa eklendi — key=$idempotencyKey, '
      'items=${items.length}, kuyruk_boyutu=${queue.length}',
      name: _logTag,
    );
  }

  /// Bekleyen tüm satışları sırayla Supabase'e gönderir.
  ///
  /// Eşzamanlılık koruması: Aynı anda yalnızca bir sync çalışır.
  /// Geri dönüş: Başarıyla gönderilen satış sayısı.
  Future<int> syncAll() async {
    // Eşzamanlılık kilidi
    if (_isSyncing) {
      developer.log(
        'sync zaten çalışıyor — atlanıyor',
        name: _logTag,
      );
      return 0;
    }

    // İnternet kontrolü
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      developer.log(
        'internet yok — sync atlanıyor',
        name: _logTag,
      );
      return 0;
    }

    _isSyncing = true;

    try {
      final queue = await _loadQueue();
      if (queue.isEmpty) {
        developer.log('kuyruk boş — sync yapılacak bir şey yok', name: _logTag);
        return 0;
      }

      developer.log(
        'sync başlıyor — ${queue.length} bekleyen satış',
        name: _logTag,
      );

      final client = Supabase.instance.client;
      final List<QueuedSale> remaining = [];
      final List<QueuedSale> deadLetters = [];
      int successCount = 0;

      for (final sale in queue) {
        try {
          await client.rpc('complete_sale', params: {
            'p_items': sale.items,
            'p_idempotency_key': sale.idempotencyKey,
          });

          successCount++;
          developer.log(
            'sync başarılı — key=${sale.idempotencyKey}',
            name: _logTag,
          );
        } on PostgrestException catch (e) {
          final msg = e.message;

          // Idempotency: Aynı key zaten işlendiyse başarılı say
          if (_isDuplicateKeyError(msg)) {
            successCount++;
            developer.log(
              'idempotent — zaten işlenmiş, key=${sale.idempotencyKey}',
              name: _logTag,
            );
            continue;
          }

          // Kalıcı iş kuralı hatası → anında dead letter
          if (_isPermanentError(msg)) {
            sale.lastError = msg;
            deadLetters.add(sale);
            developer.log(
              'kalıcı hata → dead letter — key=${sale.idempotencyKey}, '
              'hata=$msg',
              name: _logTag,
              level: 900,
            );
            continue;
          }

          // Geçici hata → retry sayacını artır
          sale.retryCount++;
          sale.lastError = msg;

          if (sale.retryCount >= _maxRetries) {
            deadLetters.add(sale);
            developer.log(
              'max retry aşıldı → dead letter — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}, hata=$msg',
              name: _logTag,
              level: 900,
            );
          } else {
            remaining.add(sale);
            developer.log(
              'geçici hata — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}/$_maxRetries, hata=$msg',
              name: _logTag,
              level: 800,
            );
          }
        } catch (e) {
          // Ağ hatası vb. — retry
          sale.retryCount++;
          sale.lastError = e.toString();

          if (sale.retryCount >= _maxRetries) {
            deadLetters.add(sale);
            developer.log(
              'max retry aşıldı → dead letter — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}, hata=$e',
              name: _logTag,
              level: 900,
            );
          } else {
            remaining.add(sale);
            developer.log(
              'ağ hatası — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}/$_maxRetries, hata=$e',
              name: _logTag,
              level: 800,
            );
          }
        }
      }

      // Kuyruğu güncelle
      await _saveQueue(remaining);

      // Dead letter'ları kaydet
      if (deadLetters.isNotEmpty) {
        await _appendDeadLetters(deadLetters);
      }

      developer.log(
        'sync tamamlandı — başarılı=$successCount, '
        'kalan=${remaining.length}, dead_letter=${deadLetters.length}',
        name: _logTag,
      );

      return successCount;
    } finally {
      _isSyncing = false;
    }
  }

  /// Bekleyen satış sayısını döndürür.
  Future<int> getPendingCount() async {
    final queue = await _loadQueue();
    return queue.length;
  }

  /// Dead letter kuyruğundaki satışları döndürür.
  Future<List<QueuedSale>> getDeadLetters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_deadLetterKey) ?? [];
    return raw
        .map((json) => QueuedSale.fromJson(
            jsonDecode(json) as Map<String, dynamic>))
        .toList();
  }

  /// Dead letter kuyruğunu temizler.
  Future<void> clearDeadLetters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_deadLetterKey);
    developer.log('dead letter kuyruğu temizlendi', name: _logTag);
  }

  /// Senkronizasyon çalışıyor mu?
  bool get isSyncing => _isSyncing;

  // ---------------------------------------------------------------------------
  // PRIVATE HELPERS
  // ---------------------------------------------------------------------------

  Future<List<QueuedSale>> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingKey) ?? [];
    return raw
        .map((json) => QueuedSale.fromJson(
            jsonDecode(json) as Map<String, dynamic>))
        .toList();
  }

  Future<void> _saveQueue(List<QueuedSale> queue) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = queue.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_pendingKey, raw);
  }

  Future<void> _appendDeadLetters(List<QueuedSale> newDeadLetters) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_deadLetterKey) ?? [];
    final appended = [
      ...existing,
      ...newDeadLetters.map((s) => jsonEncode(s.toJson())),
    ];
    await prefs.setStringList(_deadLetterKey, appended);
  }

  /// Duplicate idempotency_key hatası mı?
  /// PostgreSQL unique_violation kodu: 23505
  bool _isDuplicateKeyError(String message) {
    return message.contains('unique') ||
        message.contains('duplicate') ||
        message.contains('23505') ||
        message.contains('IDEMPOTENT_TEKRAR');
  }

  /// Kalıcı iş kuralı hatası mı? (retry etmenin anlamı yok)
  bool _isPermanentError(String message) {
    return message.contains('SATIS_HATA:GECERSIZ_URUN') ||
        message.contains('SATIS_HATA:ISLETME_BULUNAMADI') ||
        message.contains('SATIS_HATA:KIMLIK_DOGRULANAMADI') ||
        message.contains('SATIS_HATA:GECERSIZ_MIKTAR') ||
        message.contains('SATIS_HATA:TEKRAR_URUN_ID') ||
        message.contains('SATIS_HATA:SEPET_BOS') ||
        message.contains('SATIS_HATA:GECERSIZ_UUID_FORMAT');
  }
}
