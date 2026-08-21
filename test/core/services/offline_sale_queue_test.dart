import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perakende_app/core/services/offline_sale_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('soft-delete veya erişilemeyen ürün satışı anında dead-letter olur',
      () async {
    final queue = OfflineSaleQueue.instance;
    await queue.enqueue(
      idempotencyKey: '00000000-0000-4000-8000-000000000001',
      items: const [
        {'product_id': '00000000-0000-4000-8000-000000000002', 'quantity': 1},
      ],
    );

    final synced = await queue.syncAll(
      connectivityChecker: () async => [ConnectivityResult.wifi],
      rpcCaller: (_, __) async => throw const PostgrestException(
        message: 'SATIS_HATA:GECERSIZ_URUN',
      ),
    );

    expect(synced, 0);
    expect(await queue.getPendingCount(), 0);
    final deadLetters = await queue.getDeadLetters();
    expect(deadLetters, hasLength(1));
    expect(deadLetters.single.retryCount, 0);
    expect(deadLetters.single.lastError, contains('SATIS_HATA:GECERSIZ_URUN'));
  });

  test('geçici ağ hatası pending kaydı korur ve retry sayısını artırır',
      () async {
    final queue = OfflineSaleQueue.instance;
    await queue.enqueue(
      idempotencyKey: '00000000-0000-4000-8000-000000000003',
      items: const [
        {'product_id': '00000000-0000-4000-8000-000000000004', 'quantity': 1},
      ],
    );

    final synced = await queue.syncAll(
      connectivityChecker: () async => [ConnectivityResult.wifi],
      rpcCaller: (_, __) async => throw Exception('network down'),
    );

    expect(synced, 0);
    expect(await queue.getPendingCount(), 1);
    expect(await queue.getDeadLetters(), isEmpty);
  });
}
