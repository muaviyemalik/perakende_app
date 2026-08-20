import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

void setupSqfliteTestHelper() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // sqflite_common_ffi kullanarak Windows ortamında SQLite'ı başlat
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Mock path_provider for LocalDatabase._initDb()
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        final tempDir = await Directory.systemTemp.createTemp('sqflite_test_');
        return tempDir.path;
      }
      return null;
    },
  );
}
