import 'dart:async';
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
//   Kuyruğu okuyup-değiştirip-yazan HER işlem (_synchronized) kilidi altında
//   yapılır. syncAll ağ çağrılarını kilit DIŞINDA yapar, sonuçları en sonda
//   kuyruğun o anki haline anahtar bazında uygular. Böylece sync sürerken
//   enqueue edilen satış, sync'in elindeki eski kopyayla ezilip kaybolmaz.
//
// KALICI HATA YÖNETİMİ:
//   - Ağ hataları (sunucuya ulaşılamadı / yanıt kayboldu): retry sayılmaz,
//     satış kuyrukta kalır. Aynı idempotency_key ile tekrar gönderilmesi
//     güvenlidir; sunucu satışı daha önce kaydettiyse tekrar kaydetmez.
//   - Sunucunun döndürdüğü kalıcı iş kuralı hataları: anında dead letter'a
//   - Sunucunun döndürdüğü diğer hatalar 3 denemeden sonra dead letter'a
//   - Dead letter önce yazılır, sonra kuyruktan silinir: arada uygulama
//     kapanırsa satış kaybolmaz, en kötü ihtimalle iki yerde görünür.
// =============================================================================

const _logTag = 'OFFLINE_QUEUE';
const _pendingKey = 'offline_sale_queue';
const _deadLetterKey = 'offline_sale_dead_letters';
const _maxRetries = 3;
const _scopeVersion = 1;
const _missingScopeError = 'OFFLINE_QUEUE_QUARANTINED:SCOPE_MISSING';

/// Verified authenticated identity that owns an offline sale.
class OfflineSaleScope {
  const OfflineSaleScope({required this.userId, required this.isletmeId});

  final String userId;
  final int isletmeId;

  bool get isValid => userId.trim().isNotEmpty && isletmeId > 0;
}

/// Kuyruğa alınan tek bir satış kaydı.
class QueuedSale {
  QueuedSale({
    required this.idempotencyKey,
    required this.items,
    required this.createdAt,
    this.userId,
    this.isletmeId,
    this.retryCount = 0,
    this.lastError,
  });

  final String idempotencyKey;
  final List<Map<String, dynamic>> items;
  final String createdAt;
  final String? userId;
  final int? isletmeId;
  int retryCount;
  String? lastError;

  Map<String, dynamic> toJson() => {
        'idempotency_key': idempotencyKey,
        'items': items,
        'created_at': createdAt,
        'scope_version': _scopeVersion,
        'user_id': userId,
        'isletme_id': isletmeId,
        'retry_count': retryCount,
        'last_error': lastError,
      };

  factory QueuedSale.fromJson(Map<String, dynamic> json) {
    final rawUserId = json['user_id'];
    final rawIsletmeId = json['isletme_id'];
    final parsedIsletmeId = rawIsletmeId is int
        ? rawIsletmeId
        : rawIsletmeId is num
            ? rawIsletmeId.toInt()
            : int.tryParse(rawIsletmeId?.toString() ?? '');

    return QueuedSale(
      idempotencyKey: json['idempotency_key'] as String,
      items: (json['items'] as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      createdAt: json['created_at'] as String,
      userId:
          rawUserId is String && rawUserId.trim().isNotEmpty ? rawUserId : null,
      isletmeId: parsedIsletmeId,
      retryCount: (json['retry_count'] as int?) ?? 0,
      lastError: json['last_error'] as String?,
    );
  }

  bool get hasValidScope =>
      userId != null && userId!.trim().isNotEmpty && (isletmeId ?? 0) > 0;

  bool belongsTo(OfflineSaleScope scope) =>
      hasValidScope && userId == scope.userId && isletmeId == scope.isletmeId;
}

class OfflineSaleQueue {
  OfflineSaleQueue._();
  static final OfflineSaleQueue instance = OfflineSaleQueue._();

  static const _uuid = Uuid();
  bool _isSyncing = false;

  /// Kuyruk üzerindeki oku-değiştir-yaz işlemlerini sıraya sokan basit kilit.
  /// Her çağrı bir öncekinin bitmesini bekler.
  Future<void> _lock = Future<void>.value();

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final previous = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  // ---------------------------------------------------------------------------
  // PUBLIC API
  // ---------------------------------------------------------------------------

  /// Yeni idempotency key üretir (UUID v4).
  /// Online satışlar için de kullanılır — her satışın benzersiz kimliği olur.
  String generateKey() => _uuid.v4();

  /// Satışı kuyruğa ekler. Ürünlerden yalnızca product_id ve quantity;
  /// sahiplik doğrulaması için de verified user_id/isletme_id saklanır.
  /// Fiyat ve satış satırlarındaki authoritative tenant DB tarafında belirlenir.
  Future<void> enqueue({
    required String idempotencyKey,
    required List<Map<String, dynamic>> items,
    required OfflineSaleScope scope,
  }) async {
    if (!scope.isValid) {
      throw StateError('Offline sale scope could not be verified.');
    }

    final sale = QueuedSale(
      idempotencyKey: idempotencyKey,
      items: items,
      createdAt: DateTime.now().toIso8601String(),
      userId: scope.userId,
      isletmeId: scope.isletmeId,
    );

    await _synchronized(() async {
      final queue = await _loadQueue();
      // Aynı satış (aynı key) iki kez kuyruğa girmesin.
      if (queue.any((s) => s.idempotencyKey == idempotencyKey)) return;
      queue.add(sale);
      await _saveQueue(queue);

      developer.log(
        'satış kuyruğa eklendi — key=$idempotencyKey, '
        'items=${items.length}, kuyruk_boyutu=${queue.length}',
        name: _logTag,
      );
    });
  }

  /// Bekleyen tüm satışları sırayla Supabase'e gönderir.
  ///
  /// Eşzamanlılık koruması: Aynı anda yalnızca bir sync çalışır.
  /// Geri dönüş: Başarıyla gönderilen satış sayısı.
  Future<int> syncAll({
    required OfflineSaleScope? currentScope,
    Future<List<ConnectivityResult>> Function()? connectivityChecker,
    Future<dynamic> Function(String, Map<String, dynamic>)? rpcCaller,
  }) async {
    // Eşzamanlılık kilidi
    if (_isSyncing) {
      developer.log(
        'sync zaten çalışıyor — atlanıyor',
        name: _logTag,
      );
      return 0;
    }

    _isSyncing = true;

    try {
      // ---- 1. AŞAMA (kilitli): eski kayıtları karantinaya al, kopya çıkar ----
      final snapshot = await _synchronized(() async {
        final queue = await _loadQueue();
        final unscoped = queue.where((sale) => !sale.hasValidScope).toList();
        if (unscoped.isNotEmpty) {
          // Legacy records have no trustworthy owner. Never let them inherit
          // the next account's session: quarantine them before any RPC.
          for (final sale in unscoped) {
            sale.lastError = _missingScopeError;
          }
          // Önce dead letter'a yaz, sonra kuyruktan sil (kayıp olmasın).
          await _appendDeadLetters(unscoped);
          await _saveQueue(
            queue.where((sale) => sale.hasValidScope).toList(),
          );
        }
        return queue.where((sale) => sale.hasValidScope).toList();
      });

      if (snapshot.isEmpty) {
        developer.log('kuyruk boş — sync yapılacak bir şey yok', name: _logTag);
        return 0;
      }

      // Auth/session or tenant lookup failure is fail-closed.
      if (currentScope == null || !currentScope.isValid) {
        developer.log(
          'oturum kapsamı doğrulanamadı — sync reddedildi',
          name: _logTag,
          level: 900,
        );
        return 0;
      }

      // İnternet kontrolü only after local legacy quarantine.
      final connectivityResult = connectivityChecker == null
          ? await Connectivity().checkConnectivity()
          : await connectivityChecker();
      if (connectivityResult.contains(ConnectivityResult.none)) {
        developer.log(
          'internet yok — sync atlanıyor',
          name: _logTag,
        );
        return 0;
      }

      developer.log(
        'sync başlıyor — ${snapshot.length} bekleyen satış',
        name: _logTag,
      );

      // ---- 2. AŞAMA (kilitsiz): ağ çağrıları ----
      // Sonuçlar anahtar bazında toplanır; kuyruğa en sonda uygulanır.
      final Set<String> completedKeys = {};
      final Map<String, QueuedSale> deadLetters = {};
      final Map<String, QueuedSale> retried = {};

      for (final sale in snapshot) {
        if (!sale.belongsTo(currentScope)) {
          // Preserve it for its original owner without incrementing retries.
          continue;
        }

        // Döngü sürerken kasiyer değiştiyse, satışı yeni oturumla
        // gönderme — sunucu satışı yeni kullanıcıya yazardı.
        if (rpcCaller == null &&
            Supabase.instance.client.auth.currentUser?.id !=
                currentScope.userId) {
          developer.log(
            'oturum sync sırasında değişti — sync durduruldu',
            name: _logTag,
            level: 900,
          );
          break;
        }

        try {
          final params = {
            'p_items': sale.items,
            'p_idempotency_key': sale.idempotencyKey,
          };
          if (rpcCaller == null) {
            await Supabase.instance.client.rpc('complete_sale', params: params);
          } else {
            await rpcCaller('complete_sale', params);
          }

          completedKeys.add(sale.idempotencyKey);
          developer.log(
            'sync başarılı — key=${sale.idempotencyKey}',
            name: _logTag,
          );
        } on PostgrestException catch (e) {
          final msg = e.message;

          // Idempotency: Aynı key zaten işlendiyse başarılı say
          if (isAlreadyProcessedError(e)) {
            completedKeys.add(sale.idempotencyKey);
            developer.log(
              'idempotent — zaten işlenmiş, key=${sale.idempotencyKey}',
              name: _logTag,
            );
            continue;
          }

          // Kalıcı iş kuralı hatası → anında dead letter
          if (_isPermanentError(msg)) {
            sale.lastError = msg;
            deadLetters[sale.idempotencyKey] = sale;
            developer.log(
              'kalıcı hata → dead letter — key=${sale.idempotencyKey}, '
              'hata=$msg',
              name: _logTag,
              level: 900,
            );
            continue;
          }

          // Sunucunun döndürdüğü diğer hatalar → retry sayacını artır
          sale.retryCount++;
          sale.lastError = msg;

          if (sale.retryCount >= _maxRetries) {
            deadLetters[sale.idempotencyKey] = sale;
            developer.log(
              'max retry aşıldı → dead letter — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}, hata=$msg',
              name: _logTag,
              level: 900,
            );
          } else {
            retried[sale.idempotencyKey] = sale;
            developer.log(
              'geçici hata — key=${sale.idempotencyKey}, '
              'retry=${sale.retryCount}/$_maxRetries, hata=$msg',
              name: _logTag,
              level: 800,
            );
          }
        } catch (e) {
          // Ağ hatası: sunucuya ulaşılamadı ya da yanıt kayboldu. Satış
          // sunucuda kaydedilmiş olabilir; aynı key ile tekrar göndermek
          // güvenli olduğu için dead letter'a ATILMAZ, retry sayılmaz.
          sale.lastError = e.toString();
          retried[sale.idempotencyKey] = sale;
          developer.log(
            'ağ hatası — kuyrukta kalıyor, key=${sale.idempotencyKey}, '
            'hata=$e',
            name: _logTag,
            level: 800,
          );
        }
      }

      // ---- 3. AŞAMA (kilitli): sonuçları kuyruğun GÜNCEL haline uygula ----
      // Sync sürerken enqueue edilen satışlar `current` içinde olduğu için
      // korunur; yalnızca bu turda sonuçlanan anahtarlar değişir.
      final remainingCount = await _synchronized(() async {
        if (deadLetters.isNotEmpty) {
          await _appendDeadLetters(deadLetters.values.toList());
        }
        final current = await _loadQueue();
        final updated = <QueuedSale>[];
        for (final sale in current) {
          final key = sale.idempotencyKey;
          if (completedKeys.contains(key) || deadLetters.containsKey(key)) {
            continue;
          }
          updated.add(retried[key] ?? sale);
        }
        await _saveQueue(updated);
        return updated.length;
      });

      final successCount = completedKeys.length;
      developer.log(
        'sync tamamlandı — başarılı=$successCount, '
        'kalan=$remainingCount, dead_letter=${deadLetters.length}',
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
        .map((json) =>
            QueuedSale.fromJson(jsonDecode(json) as Map<String, dynamic>))
        .toList();
  }

  /// Dead letter kuyruğunu temizler.
  Future<void> clearDeadLetters() => _synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_deadLetterKey);
        developer.log('dead letter kuyruğu temizlendi', name: _logTag);
      });

  /// Senkronizasyon çalışıyor mu?
  bool get isSyncing => _isSyncing;

  // ---------------------------------------------------------------------------
  // PRIVATE HELPERS
  // ---------------------------------------------------------------------------

  Future<List<QueuedSale>> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pendingKey) ?? [];
    return raw
        .map((json) =>
            QueuedSale.fromJson(jsonDecode(json) as Map<String, dynamic>))
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

  /// Bu satış (aynı idempotency_key) sunucuda zaten işlenmiş mi?
  ///
  /// Yalnızca satış idempotency indeksine ait unique_violation (23505)
  /// başarı sayılır. Eskiden mesajında "unique"/"duplicate" geçen HER hata
  /// başarı sayılıyordu; başka bir kısıt ihlali satışı sessizce siliyordu.
  static bool isAlreadyProcessedError(PostgrestException e) {
    if (e.message.contains('IDEMPOTENT_TEKRAR')) return true;
    final text = '${e.message} ${e.details ?? ''}';
    return e.code == '23505' &&
        text.contains('idx_sales_idempotency_key_unique');
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
