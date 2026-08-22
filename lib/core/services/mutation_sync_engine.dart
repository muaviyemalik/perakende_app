import 'dart:convert';
import 'dart:developer' as developer;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/offline_mutation_dao.dart';
import '../utils/product_error_mapper.dart';

// =============================================================================
// MutationSyncEngine — Offline mutasyon kuyruğunu işler
// =============================================================================
//
// AMAÇ:
//   Local SQLite içindeki `offline_product_mutations` tablosunda bulunan
//   PENDING durumdaki mutasyonları Supabase'e sırayla (FIFO) gönderir.
//
// GÜVENLİK:
//   Sadece `currentIsletmeId` ile eşleşen kayıtları gönderir!
// =============================================================================

class MutationSyncEngine {
  MutationSyncEngine._();
  static final MutationSyncEngine instance = MutationSyncEngine._();

  static const _logTag = 'MUTATION_SYNC';
  static const int _maxRetries = 3;

  bool _isSyncing = false;

  /// Bekleyen mutasyonları gönderir.
  Future<void> syncPendingMutations(int currentIsletmeId,
      {Future<dynamic> Function(String, Map<String, dynamic>)?
          rpcCaller}) async {
    if (_isSyncing) {
      developer.log('Senkronizasyon zaten çalışıyor.', name: _logTag);
      return;
    }

    bool hasInternet = true;
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        hasInternet = false;
      }
    } catch (e) {
      // Test ortamında MissingPluginException vb. atılabilir
      developer.log(
          'Connectivity kontrolü yapılamadı (Test ortamı olabilir): $e',
          name: _logTag);
    }

    if (!hasInternet) {
      developer.log('İnternet yok, mutasyon sync atlanıyor.', name: _logTag);
      return;
    }

    _isSyncing = true;
    try {
      final dao = OfflineMutationDao.instance;
      final pendingMutations = await dao.getPendingMutations(currentIsletmeId);

      if (pendingMutations.isEmpty) {
        developer.log('Bekleyen mutasyon yok.', name: _logTag);
        return;
      }

      developer.log(
        '${pendingMutations.length} bekleyen mutasyon işleniyor...',
        name: _logTag,
      );

      for (final mutation in pendingMutations) {
        final int id = mutation['id'] as int;
        final String idempotencyKey = mutation['idempotency_key'] as String;
        final int isletmeId = mutation['isletme_id'] as int;
        final String operationType = mutation['operation_type'] as String;
        final String productId = mutation['product_id'] as String;
        final String? payloadStr = mutation['payload'] as String?;
        final String? baseUpdatedAtStr = mutation['base_updated_at'] as String?;
        final int currentRetries = mutation['retry_count'] as int;

        // Çift güvenlik kontrolü (İşletme ID'si uyuşmazsa kesinlikle atla)
        if (isletmeId != currentIsletmeId) {
          developer.log(
            'Güvenlik ihlali: mutation tenant = $isletmeId, user tenant = $currentIsletmeId',
            name: _logTag,
            level: 1000,
          );
          continue;
        }

        try {
          final payloadJson =
              payloadStr != null ? jsonDecode(payloadStr) : null;

          final params = {
            'p_idempotency_key': idempotencyKey,
            'p_isletme_id': isletmeId,
            'p_operation_type': operationType,
            'p_product_id': productId,
            'p_payload': payloadJson,
            'p_base_updated_at': baseUpdatedAtStr,
          };

          if (rpcCaller != null) {
            await rpcCaller('process_product_mutation', params);
          } else {
            await Supabase.instance.client
                .rpc('process_product_mutation', params: params);
          }

          // Başarılı
          await dao.updateStatus(id, 'SYNCED');
          developer.log('Mutasyon başarılı: id=$id, type=$operationType',
              name: _logTag);
        } on PostgrestException catch (e) {
          final String msg = e.message;

          if (msg.contains('IDEMPOTENT_TEKRAR')) {
            await dao.updateStatus(id, 'SYNCED');
            developer.log('Mutasyon (Idempotent): id=$id', name: _logTag);
          } else if (isTenantBarcodeUniqueViolation(e)) {
            await dao.updateStatus(
              id,
              'DEAD_LETTER',
              lastError: duplicateProductBarcodeMessage,
            );
            developer.log(
              'Kalıcı barkod çakışması (DEAD_LETTER): id=$id',
              name: _logTag,
              level: 900,
            );
          } else if (_isPermanentError(msg)) {
            // Yetki, Çakışma (CONFLICT), Validasyon -> DEAD_LETTER
            await dao.updateStatus(id, 'DEAD_LETTER', lastError: msg);
            developer.log('Kalıcı hata (DEAD_LETTER): id=$id, hata=$msg',
                name: _logTag, level: 900);
          } else {
            // Geçici hata -> Retry
            final int nextRetry = currentRetries + 1;
            if (nextRetry >= _maxRetries) {
              await dao.updateStatus(id, 'DEAD_LETTER',
                  lastError: 'Max retries exceeded: $msg');
              developer.log('Max retry aşıldı (DEAD_LETTER): id=$id, hata=$msg',
                  name: _logTag, level: 900);
            } else {
              await dao.updateStatus(id, 'PENDING',
                  lastError: msg, retryCount: nextRetry);
              developer.log('Geçici hata (Retry $nextRetry): id=$id, hata=$msg',
                  name: _logTag, level: 800);
              // FIFO kuralları gereği, biri geçici hataya düşerse diğerlerine devam edemeyiz (çünkü sıralama önemli olabilir)
              // Bu yüzden break yapıp mevcut döngüyü kırıyoruz ki, sonraki sync tekrar başa dönsün.
              break;
            }
          }
        } catch (e) {
          // Network veya diğer hatalar -> Retry
          final int nextRetry = currentRetries + 1;
          if (nextRetry >= _maxRetries) {
            await dao.updateStatus(id, 'DEAD_LETTER',
                lastError: 'Max retries exceeded: $e');
            developer.log('Max retry aşıldı (DEAD_LETTER): id=$id, hata=$e',
                name: _logTag, level: 900);
          } else {
            await dao.updateStatus(id, 'PENDING',
                lastError: e.toString(), retryCount: nextRetry);
            developer.log('Ağ hatası (Retry $nextRetry): id=$id, hata=$e',
                name: _logTag, level: 800);
            break; // FIFO kuralı gereği döngüyü kır
          }
        }
      }
    } finally {
      _isSyncing = false;
    }
  }

  bool _isPermanentError(String message) {
    return message.contains('AUTH_REQUIRED') ||
        message.contains('PRODUCT_MUTATION_FORBIDDEN') ||
        message.contains('CONFLICT_DETECTED') ||
        message.contains('TENANT_MISMATCH') ||
        message.contains('INVALID_OPERATION_TYPE') ||
        message.contains('permission denied') ||
        message.contains('POLICY') ||
        message.contains('PRODUCT_NOT_FOUND');
  }
}
