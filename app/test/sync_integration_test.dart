@Tags(['server'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/services/sync/sync_service.dart';
import 'package:pos_terminal/state/cart.dart';
import 'package:drift/drift.dart' show Value;

import 'test_helpers.dart';

/// Ikki qurilma (notebook va telefon) uchma-uch sinxronlash testi.
/// Ishga tushirish: server ishlab turgan bo'lsin, so'ng
///   SYNC_TEST_URL=http://127.0.0.1:8000 SYNC_TEST_KEY=... flutter test test/sync_integration_test.dart
void main() {
  final url = Platform.environment['SYNC_TEST_URL'];
  final key = Platform.environment['SYNC_TEST_KEY'] ?? '';

  Future<(TestEnv, SyncService)> device(String code) async {
    final env = TestEnv();
    await env.settings.setAll({
      SettingKeys.syncEnabled: '1',
      SettingKeys.syncUrl: url!,
      SettingKeys.syncApiKey: key,
      SettingKeys.deviceCode: code,
    });
    final sync = SyncService(db: env.db, settings: env.settings, stock: env.stock, stats: env.stats, alerts: env.alerts);
    return (env, sync);
  }

  test("ulanishni tekshirish API kalitni ham tekshiradi", () async {
    final (env, sync) = await device('K9');
    expect(await sync.testConnection(), contains("to'g'ri"));
    await env.settings.set(SettingKeys.syncApiKey, 'notogri-kalit');
    expect(sync.testConnection(), throwsA(isA<SyncException>()));
  }, skip: url == null ? 'SYNC_TEST_URL berilmagan' : null);

  test('ikki qurilma offline sotadi, keyin sinxronlanadi', () async {
    final (a, syncA) = await device('K1');
    final (b, syncB) = await device('T1');
    final adminA = await a.users.login('admin', 'admin123');

    // A da tovar yaratiladi (10 dona) va serverga yuboriladi.
    final p = await a.addProduct('Elektr isitgich', price: 420000, stock: 10, min: 2, barcode: '4781234567890');
    await syncA.syncNow();
    expect(syncA.status.value.state, SyncState.ok, reason: syncA.status.value.message);

    // B serverdan oladi — qoldiq harakatlardan hisoblanadi.
    await syncB.syncNow();
    final pb = await b.products.findByBarcode('4781234567890');
    expect(pb, isNotNull);
    expect(pb!.stockQty, 10);

    // Ikkalasi ham "offline" holda bir vaqtda sotadi: A 3 ta, B 4 ta.
    final adminB = await b.users.login('admin', 'admin123');
    await a.checkout.checkout(
        cart: CartState(lines: [CartLine(product: p, qty: 3)]), payment: const PaymentInput(cash: 1260000), cashier: adminA);
    await b.checkout.checkout(
        cart: CartState(lines: [CartLine(product: pb, qty: 4)]), payment: const PaymentInput(card: 1680000), cashier: adminB);

    await syncA.syncNow();
    await syncB.syncNow();
    await syncA.syncNow();

    // Ikkala qurilmada ham qoldiq: 10 - 3 - 4 = 3 (konfliktsiz qo'shildi).
    expect((await a.products.byId(p.id))!.stockQty, 3);
    expect((await b.products.byId(p.id))!.stockQty, 3);
    // Cheklar ikkala qurilmada ham bor, raqamlar to'qnashmaydi.
    final salesA = await a.db.select(a.db.sales).get();
    expect(salesA.map((s) => s.receiptNo).toSet(), {'K1-000001', 'T1-000001'});
    expect(await syncA.pendingCount(), 0);

    // Narx konflikti: B avval, A keyinroq o'zgartiradi -> A (oxirgi yozuv) yutadi.
    await b.products.save(ProductsCompanion(id: Value(p.id), salePrice: const Value(450000)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await a.products.save(ProductsCompanion(id: Value(p.id), salePrice: const Value(399000)));
    await syncB.syncNow();
    await syncA.syncNow();
    await syncB.syncNow();
    expect((await a.products.byId(p.id))!.salePrice, 399000);
    expect((await b.products.byId(p.id))!.salePrice, 399000);

    // Qaytarish B da -> A da ham chek "qaytarilgan", qoldiq tiklanadi.
    final saleOnB = (await b.db.select(b.db.sales).get()).firstWhere((s) => s.receiptNo == 'K1-000001');
    await b.checkout.refund((await b.sales.getWithItems(saleOnB.id))!, adminB);
    await syncB.syncNow();
    await syncA.syncNow();
    final refundedOnA = (await a.sales.getWithItems(saleOnB.id))!.sale;
    expect(refundedOnA.status, SaleStatus.refunded.code);
    expect((await a.products.byId(p.id))!.stockQty, 6);
    expect((await b.products.byId(p.id))!.stockQty, 6);

    // Server o'chiq bo'lsa ham savdo davom etadi (offline).
    await a.settings.set(SettingKeys.syncUrl, 'http://127.0.0.1:9');
    await syncA.syncNow();
    expect(syncA.status.value.state, SyncState.offline);
    await a.checkout.checkout(
        cart: CartState(lines: [CartLine(product: (await a.products.byId(p.id))!, qty: 1)]),
        payment: const PaymentInput(cash: 399000),
        cashier: adminA);
    expect(await syncA.pendingCount(), greaterThan(0));

    await a.close();
    await b.close();
  }, skip: url == null ? 'SYNC_TEST_URL berilmagan' : null);
}
