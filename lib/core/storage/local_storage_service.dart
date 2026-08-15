import 'package:shared_preferences/shared_preferences.dart';

class LocalStorageService {
  static const String _isletmeIdKey = 'isletme_id';

  static Future<void> saveIsletmeId(int isletmeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_isletmeIdKey, isletmeId);
  }

  static Future<int?> getIsletmeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_isletmeIdKey);
  }

  static Future<void> clearIsletmeId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_isletmeIdKey);
  }
}
