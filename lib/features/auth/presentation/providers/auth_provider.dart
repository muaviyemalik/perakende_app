import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/local_product_dao.dart';
import '../../../../core/database/offline_mutation_dao.dart';
import '../../../../core/database/sync_metadata_dao.dart';
import '../../../../core/providers/supabase_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../data/kullanici_servisi.dart';
import '../../domain/kullanici_data.dart';

export '../../domain/kullanici_data.dart';

const _logTag = 'AUTH';

final kullaniciServisiProvider = Provider<KullaniciServisi>((ref) {
  return KullaniciServisi(ref.watch(supabaseClientProvider));
});

final authStateProvider = StreamProvider<Session?>((ref) {
  final supabase = ref.watch(supabaseClientProvider);
  return supabase.auth.onAuthStateChange.map((data) => data.session);
});

final isUserLoggedInProvider = Provider<bool>((ref) {
  final session = ref.watch(authStateProvider);
  return session.maybeWhen(
    data: (session) => session != null,
    orElse: () => false,
  );
});

final currentUserProvider = Provider<User?>((ref) {
  final session = ref.watch(authStateProvider);
  return session.maybeWhen(
    data: (session) => session?.user,
    orElse: () => null,
  );
});

/// Auth oturumu ile kullanicilar tablosu arasındaki köprü.
/// auth.users.id = kullanicilar.id eşleşmesi beklenir.
final kullaniciProvider = FutureProvider<KullaniciLoadResult>((ref) async {
  final currentUser = ref.watch(currentUserProvider);

  if (currentUser == null) {
    return const KullaniciLoadResult();
  }

  developer.log(
    'kullanici yükleniyor — authUserId=${currentUser.id}',
    name: _logTag,
  );

  try {
    final servis = ref.watch(kullaniciServisiProvider);
    final data = await servis.getKullaniciByAuthId(currentUser.id);

    await LocalStorageService.saveIsletmeId(data.isletmeId);

    developer.log(
      'kullanici yüklendi — rol=${data.rol}, isletme_id=${data.isletmeId}, '
      'sifre_degisti_mi=${data.sifreDegistiMi}',
      name: _logTag,
    );

    return KullaniciLoadResult(data: data);
  } on KullaniciServisiException catch (e) {
    developer.log(
      'kullanici yüklenemedi — tip=${e.tip}, message=${e.message}, '
      'technical=${e.technicalDetail}',
      name: _logTag,
      level: 1000,
    );
    return KullaniciLoadResult(
      hataMesaji: e.message,
      hataTipi: e.tip,
    );
  } catch (e, stackTrace) {
    developer.log(
      'kullanici yüklenirken beklenmeyen hata — $e',
      name: _logTag,
      level: 1000,
      error: e,
      stackTrace: stackTrace,
    );
    return const KullaniciLoadResult(
      hataMesaji:
          'Kullanıcı bilgileri alınırken beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.',
      hataTipi: KullaniciHataTipi.veritabani,
    );
  }
});

final userRoleProvider = FutureProvider<String?>((ref) async {
  final result = await ref.watch(kullaniciProvider.future);
  return result.data?.rol;
});

final sifreDegistiMiProvider = FutureProvider<bool?>((ref) async {
  final result = await ref.watch(kullaniciProvider.future);
  if (result.kullaniciYuklenemedi) {
    return null;
  }
  return result.data?.sifreDegistiMi ?? true;
});

Future<void> performLogout(WidgetRef ref) async {
  // İşletme verilerini ve senkronizasyon geçmişini yerel cihazdan temizle
  final isletmeId = await LocalStorageService.getIsletmeId();
  if (isletmeId != null) {
    await LocalProductDao.instance.deleteAllForIsletme(isletmeId);
    await SyncMetadataDao.instance.clearForIsletme(isletmeId);
    await OfflineMutationDao.instance.clearForIsletme(isletmeId);
  }

  await LocalStorageService.clearIsletmeId();
  ref.invalidate(kullaniciProvider);
  await ref.read(supabaseClientProvider).auth.signOut();
}

Future<void> cleanupFailedAuthSession(WidgetRef ref) async {
  developer.log(
    'başarısız auth oturumu temizleniyor',
    name: _logTag,
    level: 900,
  );
  
  // İşletme verilerini ve senkronizasyon geçmişini yerel cihazdan temizle
  final isletmeId = await LocalStorageService.getIsletmeId();
  if (isletmeId != null) {
    await LocalProductDao.instance.deleteAllForIsletme(isletmeId);
    await SyncMetadataDao.instance.clearForIsletme(isletmeId);
    await OfflineMutationDao.instance.clearForIsletme(isletmeId);
  }

  await LocalStorageService.clearIsletmeId();
  ref.invalidate(kullaniciProvider);
  try {
    await ref.read(supabaseClientProvider).auth.signOut();
  } catch (_) {
    // Oturum zaten kapalı olabilir.
  }
}

bool shouldCleanupSessionOnKullaniciError(KullaniciHataTipi? tip) {
  return tip == KullaniciHataTipi.kayitBulunamadi ||
      tip == KullaniciHataTipi.veriEksik;
}
