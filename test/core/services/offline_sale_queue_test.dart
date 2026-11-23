import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perakende_app/core/services/offline_sale_queue.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userA = '00000000-0000-4000-8000-0000000000a1';
const _userB = '00000000-0000-4000-8000-0000000000b2';
const _scopeA = OfflineSaleScope(userId: _userA, isletmeId: 10);
const _scopeB = OfflineSaleScope(userId: _userB, isletmeId: 10);
const _otherTenant = OfflineSaleScope(userId: _userA, isletmeId: 20);
const _items = [
  {'product_id': '00000000-0000-4000-8000-000000000002', 'quantity': 1},
];

Future<void> _enqueue(
  OfflineSaleQueue queue, {
  OfflineSaleScope scope = _scopeA,
  String key = '00000000-0000-4000-8000-000000000001',
}) =>
    queue.enqueue(idempotencyKey: key, items: _items, scope: scope);

Future<int> _sync(
  OfflineSaleQueue queue, {
  required OfflineSaleScope? scope,
  Future<dynamic> Function(String, Map<String, dynamic>)? rpcCaller,
}) =>
    queue.syncAll(
      currentScope: scope,
      connectivityChecker: () async => [ConnectivityResult.wifi],
      rpcCaller: rpcCaller ?? (_, __) async => {'ok': true},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('same user and same tenant persists scope and replays', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(
      prefs.getStringList('offline_sale_queue')!.single,
    ) as Map<String, dynamic>;
    expect(persisted['scope_version'], 1);
    expect(persisted['user_id'], _userA);
    expect(persisted['isletme_id'], 10);

    var rpcCalls = 0;
    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async {
        rpcCalls++;
        return {'ok': true};
      },
    );

    expect(synced, 1);
    expect(rpcCalls, 1);
    expect(await queue.getPendingCount(), 0);
  });

  test('different user cannot replay another user queue', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);
    var rpcCalls = 0;

    expect(
      await _sync(
        queue,
        scope: _scopeB,
        rpcCaller: (_, __) async => rpcCalls++,
      ),
      0,
    );
    expect(rpcCalls, 0);
    expect(await queue.getPendingCount(), 1);
  });

  test('different tenant cannot replay another tenant queue', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);
    var rpcCalls = 0;

    expect(
      await _sync(
        queue,
        scope: _otherTenant,
        rpcCaller: (_, __) async => rpcCalls++,
      ),
      0,
    );
    expect(rpcCalls, 0);
    expect(await queue.getPendingCount(), 1);
  });

  test('logout fails closed and does not replay queued sale', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);
    var rpcCalls = 0;

    expect(
      await _sync(
        queue,
        scope: null,
        rpcCaller: (_, __) async => rpcCalls++,
      ),
      0,
    );
    expect(rpcCalls, 0);
    expect(await queue.getPendingCount(), 1);
  });

  test('account switch leaves old queue for its original owner', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    expect(await _sync(queue, scope: _scopeB), 0);
    expect(await queue.getPendingCount(), 1);
    expect(await _sync(queue, scope: _scopeA), 1);
    expect(await queue.getPendingCount(), 0);
  });

  test('legacy unscoped record is quarantined as dead letter', () async {
    SharedPreferences.setMockInitialValues({
      'offline_sale_queue': [
        jsonEncode({
          'idempotency_key': '00000000-0000-4000-8000-000000000003',
          'items': _items,
          'created_at': '2026-08-21T00:00:00.000Z',
          'retry_count': 0,
          'last_error': null,
        }),
      ],
    });
    final queue = OfflineSaleQueue.instance;
    var rpcCalls = 0;

    expect(
      await _sync(
        queue,
        scope: _scopeA,
        rpcCaller: (_, __) async => rpcCalls++,
      ),
      0,
    );
    expect(rpcCalls, 0);
    expect(await queue.getPendingCount(), 0);
    final deadLetters = await queue.getDeadLetters();
    expect(deadLetters, hasLength(1));
    expect(
      deadLetters.single.lastError,
      'OFFLINE_QUEUE_QUARANTINED:SCOPE_MISSING',
    );
    expect(deadLetters.single.userId, isNull);
    expect(deadLetters.single.isletmeId, isNull);
  });

  test('normal offline sale queue flow remains successful', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final synced = await _sync(queue, scope: _scopeA);

    expect(synced, 1);
    expect(await queue.getPendingCount(), 0);
    expect(await queue.getDeadLetters(), isEmpty);
  });

  test('soft-delete or inaccessible product remains an immediate dead letter',
      () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async => throw const PostgrestException(
        message: 'SATIS_HATA:GECERSIZ_URUN',
      ),
    );

    expect(synced, 0);
    expect(await queue.getPendingCount(), 0);
    final deadLetters = await queue.getDeadLetters();
    expect(deadLetters, hasLength(1));
    expect(deadLetters.single.retryCount, 0);
    expect(deadLetters.single.userId, _userA);
    expect(deadLetters.single.isletmeId, 10);
    expect(deadLetters.single.lastError, contains('SATIS_HATA:GECERSIZ_URUN'));
  });

  test('server-side transient failure preserves scope and increments retry',
      () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async => throw const PostgrestException(
        code: '57014',
        message: 'canceling statement due to statement timeout',
      ),
    );

    expect(synced, 0);
    expect(await queue.getPendingCount(), 1);
    expect(await queue.getDeadLetters(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final persisted = jsonDecode(
      prefs.getStringList('offline_sale_queue')!.single,
    ) as Map<String, dynamic>;
    expect(persisted['retry_count'], 1);
    expect(persisted['user_id'], _userA);
    expect(persisted['isletme_id'], 10);
  });

  test('network failure never dead-letters a possibly recorded sale',
      () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    for (var i = 0; i < 5; i++) {
      await _sync(
        queue,
        scope: _scopeA,
        rpcCaller: (_, __) async => throw Exception('network down'),
      );
    }

    expect(await queue.getPendingCount(), 1);
    expect(await queue.getDeadLetters(), isEmpty);
  });

  test('gateway 504 is treated as unknown outcome, never dead-lettered',
      () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    for (var i = 0; i < 5; i++) {
      await _sync(
        queue,
        scope: _scopeA,
        rpcCaller: (_, __) async => throw const PostgrestException(
          code: '504',
          message: 'Gateway Timeout',
        ),
      );
    }

    expect(await queue.getPendingCount(), 1);
    expect(await queue.getDeadLetters(), isEmpty);
  });

  test('sale enqueued while sync is running is not lost', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue, key: '00000000-0000-4000-8000-0000000000k1');

    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async {
        // Sync ağ çağrısını beklerken kasiyer yeni bir offline satış yapar.
        await _enqueue(queue, key: '00000000-0000-4000-8000-0000000000k2');
        return {'ok': true};
      },
    );

    expect(synced, 1);
    expect(await queue.getPendingCount(), 1);
    final prefs = await SharedPreferences.getInstance();
    final remaining = jsonDecode(
      prefs.getStringList('offline_sale_queue')!.single,
    ) as Map<String, dynamic>;
    expect(remaining['idempotency_key'], '00000000-0000-4000-8000-0000000000k2');
  });

  test('same idempotency key is queued only once', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);
    await _enqueue(queue);

    expect(await queue.getPendingCount(), 1);
  });

  test('idempotency index violation counts as already processed', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async => throw const PostgrestException(
        code: '23505',
        message: 'duplicate key value violates unique constraint '
            '"idx_sales_idempotency_key_unique"',
      ),
    );

    expect(synced, 1);
    expect(await queue.getPendingCount(), 0);
    expect(await queue.getDeadLetters(), isEmpty);
  });

  test('unrelated unique violation is not mistaken for success', () async {
    final queue = OfflineSaleQueue.instance;
    await _enqueue(queue);

    final synced = await _sync(
      queue,
      scope: _scopeA,
      rpcCaller: (_, __) async => throw const PostgrestException(
        code: '23505',
        message: 'duplicate key value violates unique constraint '
            '"some_other_unique"',
      ),
    );

    expect(synced, 0);
    expect(await queue.getPendingCount(), 1);
  });
}
