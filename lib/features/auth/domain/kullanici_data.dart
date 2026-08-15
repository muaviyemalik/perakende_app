enum KullaniciHataTipi {
  kayitBulunamadi,
  erisimEngellendi,
  veriEksik,
  veritabani,
}

class KullaniciData {
  const KullaniciData({
    required this.rol,
    required this.isletmeId,
    required this.sifreDegistiMi,
  });

  final String rol;
  final int isletmeId;
  final bool sifreDegistiMi;
}

class KullaniciLoadResult {
  const KullaniciLoadResult({
    this.data,
    this.hataMesaji,
    this.hataTipi,
  });

  final KullaniciData? data;
  final String? hataMesaji;
  final KullaniciHataTipi? hataTipi;

  bool get basarili => data != null && hataMesaji == null;
  bool get kullaniciYuklenemedi => hataMesaji != null;
}

String? dashboardPathForRol(String? rol) {
  switch (rol) {
    case 'admin':
      return '/admin-dashboard';
    case 'kasiyer':
      return '/employee-dashboard';
    default:
      return null;
  }
}

String rolGoruntule(String rol) {
  switch (rol) {
    case 'admin':
      return 'Yönetici';
    case 'kasiyer':
      return 'Kasiyer';
    default:
      return rol;
  }
}

String satisciEtiketi(
  Map<String, dynamic> sale, {
  String? currentUserId,
  String? currentUserEmail,
}) {
  final createdBy = sale['created_by']?.toString();
  if (createdBy != null &&
      createdBy == currentUserId &&
      currentUserEmail != null &&
      currentUserEmail.isNotEmpty) {
    return currentUserEmail;
  }
  if (createdBy != null && createdBy.length >= 8) {
    return 'Kasiyer ${createdBy.substring(0, 8)}';
  }
  return 'Bilinmeyen satıcı';
}
