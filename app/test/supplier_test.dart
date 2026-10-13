import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/supplier_repository.dart';

import 'test_helpers.dart';

void main() {
  late TestEnv env;
  late SupplierRepository repo;
  late User admin;

  setUp(() async {
    env = TestEnv();
    repo = SupplierRepository(env.db, () => env.settings.deviceId());
    admin = await env.users.login('admin', 'admin123');
  });

  tearDown(() => env.close());

  Future<String> purchase(String supplierId, int total, {int paid = 0, required int date}) => repo.createPurchase(
        supplierId: supplierId,
        lines: [PurchaseLineInput(productId: 'p', productName: 'Sovun', qty: total / 1000, price: 1000)],
        docDate: date,
        paidNow: paid,
        userId: admin.id,
        userName: admin.fullName,
      );

  test('kirim qisman to\'lansa qolgani qarzga yoziladi, keyin to\'lanadi', () async {
    final id = await repo.saveSupplier(name: 'Gigiena MChJ', phone: '+998901234567');
    final pid = await repo.createPurchase(
      supplierId: id,
      lines: const [
        PurchaseLineInput(productId: 'a', productName: 'Sovun', qty: 10, price: 5000),
        PurchaseLineInput(productId: 'b', productName: 'Shampun', qty: 4, price: 25000),
      ],
      docNo: '125',
      imagePaths: const ['x.jpg', 'y.jpg'],
      paidNow: 60000,
      userId: admin.id,
      userName: admin.fullName,
    );
    final p = (await env.db.select(env.db.supplierPurchases).get()).single;
    expect(p.id, pid);
    expect(p.total, 150000);
    expect(p.itemCount, 14);
    expect(splitImagePaths(p.imagePaths), ['x.jpg', 'y.jpg']);
    expect(await env.db.select(env.db.supplierPurchaseItems).get(), hasLength(2));
    expect(await repo.balanceOf(id), 90000);

    await repo.addPayment(supplierId: id, amount: 40000, userId: admin.id, userName: admin.fullName);
    expect(await repo.balanceOf(id), 50000);

    final summary = await repo.watchSummary().first;
    expect(summary.totalDebt, 50000);
    expect(summary.debtorCount, 1);
    expect(summary.paidToday, 100000);

    // Xato to'lov bekor qilinsa qarz qaytadi.
    final pay = (await repo.watchPayments(id).first).firstWhere((m) => m.amount == 40000);
    await repo.deletePayment(pay.id);
    expect(await repo.balanceOf(id), 90000);
    expect(() => repo.deleteSupplier(id), throwsException);
  });

  test("to'lovlar eng eski kirimni birinchi yopadi (FIFO) va akt-sverka qoldig'i", () async {
    final id = await repo.saveSupplier(name: 'Firma');
    await purchase(id, 100000, date: 1000);
    await purchase(id, 50000, date: 2000);
    await repo.addPayment(supplierId: id, amount: 120000, paidAt: 3000, userId: admin.id, userName: admin.fullName);

    final purchases = await repo.watchPurchases(id).first;
    final rows = SupplierRepository.allocate(purchases, 120000);
    final byDate = {for (final r in rows) r.purchase.docDate: r};
    expect(byDate[1000]!.isPaid, isTrue);
    expect(byDate[2000]!.covered, 20000);
    expect(byDate[2000]!.remaining, 30000);

    final ledger = SupplierRepository.ledger(purchases, await repo.watchPayments(id).first);
    expect(ledger.map((e) => e.balance).toList(), [30000, 150000, 100000]);
  });

  test('qarzlar ro\'yxati: eng katta qarz tepada, avans alohida', () async {
    final a = await repo.saveSupplier(name: 'A');
    final b = await repo.saveSupplier(name: 'B');
    final c = await repo.saveSupplier(name: 'C');
    await purchase(a, 10000, date: 1);
    await purchase(b, 70000, date: 1);
    await repo.addPayment(supplierId: c, amount: 5000, userId: admin.id, userName: admin.fullName);
    final list = await repo.watchBalances().first;
    expect(list.map((x) => x.supplier.name).toList(), ['B', 'A', 'C']);
    final s = await repo.watchSummary().first;
    expect(s.totalDebt, 80000);
    expect(s.totalAdvance, 5000);
    expect(() => repo.saveSupplier(name: 'b'), throwsException);
  });

  test("boshlang'ich qarz va kirimni bekor qilish", () async {
    final id = await repo.saveSupplier(name: 'Eski firma');
    await repo.createPurchase(
      supplierId: id,
      lines: const [],
      kind: PurchaseKind.opening,
      total: 300000,
      userId: admin.id,
      userName: admin.fullName,
    );
    final pid = await purchase(id, 20000, date: 5);
    expect(await repo.balanceOf(id), 320000);
    final items = await repo.deletePurchase(pid);
    expect(items, hasLength(1));
    expect(await repo.balanceOf(id), 300000);
  });

  test("eski (v1) baza yangilanganda firma jadvallari yaratiladi", () async {
    final dir = await Directory.systemTemp.createTemp('pos_mig');
    final file = File('${dir.path}/db.sqlite');
    final db1 = AppDatabase(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    for (final t in ['suppliers', 'supplier_purchases', 'supplier_purchase_items', 'supplier_payments']) {
      await db1.customStatement('DROP TABLE $t');
    }
    await db1.customStatement('PRAGMA user_version = 1');
    await db1.close();

    final db2 = AppDatabase(NativeDatabase(file));
    final r = SupplierRepository(db2, () async => 'dev');
    final id = await r.saveSupplier(name: 'Yangi');
    expect((await r.byId(id))?.name, 'Yangi');
    expect((await db2.select(db2.users).get()), isNotEmpty);
    await db2.close();
    await dir.delete(recursive: true);
  });
}
