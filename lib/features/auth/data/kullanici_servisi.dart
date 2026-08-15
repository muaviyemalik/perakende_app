import 'dart:developer' as developer;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/kullanici_data.dart';

class KullaniciServisiException implements Exception {
  KullaniciServisiException(
    this.message, {
    this.tip = KullaniciHataTipi.veritabani,
    this.technicalDetail,
  });

  final String message;
  final KullaniciHataTipi tip;
  final String? technicalDetail;

  @override
  String toString() => message;
}

class KullaniciServisi {
  const KullaniciServisi(this._client);

  final SupabaseClient _client;

  static const _selectColumns = 'id, isletme_id, rol, sifre_degisti_mi';
  static const _logTag = 'AUTH';

  /// auth.users.id ile kullanicilar.id eşleşmesi üzerinden kayıt okur.
  Future<Map<String, dynamic>> fetchKullaniciByAuthId(String authUserId) async {
    developer.log(
      'kullanicilar sorgusu başladı — tablo=kullanicilar, authUserId=$authUserId',
      name: _logTag,
    );

    try {
      final response = await _client
          .from('kullanicilar')
          .select(_selectColumns)
          .eq('id', authUserId)
          .maybeSingle();

      if (response == null) {
        developer.log(
          'kullanici bulundu = false — authUserId=$authUserId, tablo=kullanicilar, '
          'sonuç=null. Olası nedenler: kayıt yok veya RLS SELECT erişimini engelliyor.',
          name: _logTag,
          level: 900,
        );

        throw KullaniciServisiException(
          'Hesabınız uygulama sisteminde tanımlı değil. '
          'Lütfen yöneticinizle iletişime geçin.',
          tip: KullaniciHataTipi.kayitBulunamadi,
          technicalDetail:
              'SELECT kullanicilar WHERE id=$authUserId returned null',
        );
      }

      developer.log(
        'kullanici bulundu = true — id=${response['id']}, '
        'isletme_id=${response['isletme_id']}, rol=${response['rol']}, '
        'sifre_degisti_mi=${response['sifre_degisti_mi']}',
        name: _logTag,
      );

      return response;
    } on PostgrestException catch (e) {
      final erisimEngellendi = _isAccessDenied(e);

      developer.log(
        '[AUTH_DB_ERROR]\n'
        'code: ${e.code}\n'
        'message: ${e.message}\n'
        'details: ${e.details}\n'
        'hint: ${e.hint}',
        name: _logTag,
        level: 1000,
        error: e,
      );

      if (erisimEngellendi) {
        throw KullaniciServisiException(
          'Kullanıcı bilgilerine erişilirken bir veritabanı yetki hatası oluştu. '
          'Lütfen yöneticinizle iletişime geçin.',
          tip: KullaniciHataTipi.erisimEngellendi,
          technicalDetail: 'PostgrestException ${e.code}: ${e.message}',
        );
      }

      throw KullaniciServisiException(
        'Kullanıcı bilgilerine erişilirken bir veritabanı hatası oluştu. '
        'Lütfen tekrar deneyin.',
        tip: KullaniciHataTipi.veritabani,
        technicalDetail: 'PostgrestException ${e.code}: ${e.message}',
      );
    } catch (e, stackTrace) {
      if (e is KullaniciServisiException) {
        rethrow;
      }

      developer.log(
        'kullanicilar sorgusu beklenmeyen hata — authUserId=$authUserId, error=$e',
        name: _logTag,
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );

      throw KullaniciServisiException(
        'Kullanıcı bilgileri alınırken beklenmeyen bir hata oluştu. '
        'Lütfen tekrar deneyin.',
        tip: KullaniciHataTipi.veritabani,
        technicalDetail: e.toString(),
      );
    }
  }

  KullaniciData parseKullanici(Map<String, dynamic> row) {
    final authId = row['id']?.toString();
    final isletmeIdRaw = row['isletme_id'];
    final rolRaw = row['rol'] as String?;
    final sifreDegistiMi = row['sifre_degisti_mi'] as bool?;

    if (isletmeIdRaw == null) {
      developer.log(
        'isletme_id null — veri problemi, id=$authId',
        name: _logTag,
        level: 900,
      );
      throw KullaniciServisiException(
        'İşletme bilginiz tanımlı değil. Lütfen yöneticinizle iletişime geçin.',
        tip: KullaniciHataTipi.veriEksik,
        technicalDetail: 'isletme_id is null for id=$authId',
      );
    }

    final isletmeId = isletmeIdRaw is int
        ? isletmeIdRaw
        : int.tryParse(isletmeIdRaw.toString());
    if (isletmeId == null) {
      throw KullaniciServisiException(
        'İşletme bilginiz geçersiz. Lütfen yöneticinizle iletişime geçin.',
        tip: KullaniciHataTipi.veriEksik,
        technicalDetail: 'isletme_id=$isletmeIdRaw for id=$authId',
      );
    }

    final rol = _normalizeRol(rolRaw);
    if (rol == null || rol.isEmpty) {
      developer.log(
        'rol eksik veya geçersiz — id=$authId, rol=$rolRaw',
        name: _logTag,
        level: 900,
      );
      throw KullaniciServisiException(
        'Kullanıcı rol bilgisi eksik veya geçersiz. Yöneticinize başvurun.',
        tip: KullaniciHataTipi.veriEksik,
        technicalDetail: 'rol=$rolRaw',
      );
    }

    if (sifreDegistiMi == null) {
      developer.log(
        'sifre_degisti_mi null — id=$authId, force-change-password yönlendirmesi uygulanacak',
        name: _logTag,
        level: 900,
      );
    }

    return KullaniciData(
      rol: rol,
      isletmeId: isletmeId,
      sifreDegistiMi: sifreDegistiMi ?? false,
    );
  }

  Future<KullaniciData> getKullaniciByAuthId(String authUserId) async {
    final row = await fetchKullaniciByAuthId(authUserId);
    return parseKullanici(row);
  }

  bool _isAccessDenied(PostgrestException e) {
    final code = e.code?.toLowerCase() ?? '';
    final message = e.message.toLowerCase();

    return code == '42501' ||
        code == 'pgrst301' ||
        message.contains('permission denied') ||
        message.contains('row-level security') ||
        message.contains('rls');
  }

  String? _normalizeRol(String? rol) {
    if (rol == null || rol.isEmpty) {
      return null;
    }

    switch (rol.toLowerCase()) {
      case 'yonetici':
        return 'admin';
      default:
        return rol.toLowerCase();
    }
  }
}
