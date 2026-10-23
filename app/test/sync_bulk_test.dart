@Tags(['server'])
library;

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/services/sync/sync_service.dart';

import 'test_helpers.dart';

/// Ko'p yozuvli sinxronlash: minglab yuborilmagan yozuv bir necha soniyada
/// ketadi va boshqa qurilmaga to'liq keladi. Diskdagi baza (telefondagidek).
///   SYNC_TEST_URL=http://127.0.0.1:8000 SYNC_TEST_KEY=... flutter test test/sync_bulk_test.dart
void main() {
  final url = Platform.environment['SYNC_TEST_URL'];
  final key = Platform.environment['SYNC_TEST_KEY'] ?? '';
  final n = int.tryParse(Platform.environment['SYNC_BULK_N'] ?? '') ?? 3000;

  Future<(TestEnv, SyncService)> device(String code) async {
    final dir = Directory.systemTemp.createTempSync('pos_bulk_');
    final env = TestEnv(NativeDatabase(File('${dir.path}/pos.sqlite')));
    await env.settings.setAll({
      SettingKeys.syncEnabled: '1',
      SettingKeys.syncUrl: url!,
      SettingKeys.syncApiKey: key,
      SettingKeys.deviceCode: code,
    });
    final sync = SyncService(db: env.db, settings: env.settings, stock: env.stock, stats: env.stats, alerts: env.alerts);
    return (env, sync);
  }

  test('minglab yozuv tez yuboriladi va boshqa qurilmaga to\'liq keladi', () async {
    final (a, syncA) = await device('B1');
    final (b, syncB) = await device('B2');
    final p = await a.addProduct('Ommaviy tovar', stock: 1);
    final now = DateTime.now().millisecondsSinceEpoch;
    await a.db.transaction(() async {
      for (var i = 0; i < n; i++) {
        await a.db.customStatement(
          'INSERT INTO stock_movements (id, product_id, type, qty, created_at, updated_at, device_id, dirty) '
          "VALUES (?, ?, 'receipt', 1, ?, ?, 'B1', 1)",
          ['bulk-$now-$i', p.id, now + i, now + i],
        );
      }
    });
    expect(await syncA.pendingCount(), greaterThanOrEqualTo(n));

    final t = Stopwatch()..start();
    await syncA.syncNow();
    final pushMs = t.elapsedMilliseconds;
    expect(syncA.status.value.state, SyncState.ok, reason: syncA.status.value.message);
    expect(await syncA.pendingCount(), 0);

    t.reset();
    await syncB.syncNow();
    final pullMs = t.elapsedMilliseconds;
    expect(syncB.status.value.state, SyncState.ok, reason: syncB.status.value.message);
    final got = await b.db
        .customSelect('SELECT COUNT(*) c FROM stock_movements WHERE product_id = ?', variables: [Variable.withString(p.id)])
        .getSingle();
    expect(got.read<int>('c'), n + 1);
    expect((await b.products.byId(p.id))!.stockQty, n + 1);
    // ignore: avoid_print
    print('Sinxronlash $n yozuv: yuborish ${pushMs}ms, qabul ${pullMs}ms');
  }, timeout: const Timeout(Duration(minutes: 10)), skip: url == null ? 'SYNC_TEST_URL berilmagan' : null);
}
