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

  test("kam kelgan tovar qarzni kamaytiradi, firma bizga qarz bo'lishi mumkin", () async {
    final id = await repo.saveSupplier(name: 'Gigiena');
    // Prays-list bo'yicha 100 000 to'landi, lekin 80 000 lik tovar keldi.
    await purchase(id, 100000, paid: 100000, date: 1000);
    await repo.createCredit(
      supplierId: id,
      lines: const [PurchaseLineInput(productId: 'p', productName: 'Sovun', qty: 20, price: 1000)],
      note: 'kelmadi',
      userId: admin.id,
      userName: admin.fullName,
    );
    expect(await repo.balanceOf(id), -20000);
    final s = await repo.watchSummary().first;
    expect(s.totalDebt, 0);
    expect(s.totalAdvance, 20000);

    final purchases = await repo.watchPurchases(id).first;
    final rows = SupplierRepository.allocate(purchases, 100000);
    expect(rows.firstWhere((r) => r.isCredit).purchase.total, -20000);
    expect(rows.firstWhere((r) => !r.isCredit).isPaid, isTrue);

    // Firma pulni qaytaradi (imzo bilan) -> hisob yopiladi.
    await repo.addPayment(
      supplierId: id,
      amount: 20000,
      refund: true,
      receivedBy: 'Agent Ali',
      signaturePath: 'imzo.png',
      userId: admin.id,
      userName: admin.fullName,
    );
    expect(await repo.balanceOf(id), 0);
    final pays = await repo.watchPayments(id).first;
    final refund = pays.firstWhere((m) => m.amount < 0);
    expect(refund.receivedBy, 'Agent Ali');
    expect(refund.signaturePath, 'imzo.png');
    final ledger = SupplierRepository.ledger(purchases, pays);
    expect(ledger.first.debit, 20000);
    expect(ledger.first.balance, 0);
    expect(() => repo.createCredit(supplierId: id, amount: 0, userId: admin.id, userName: admin.fullName),
        throwsException);
  });

  test('kirim paytidagi to\'lovga agent imzosi yoziladi', () async {
    final id = await repo.saveSupplier(name: 'F');
    await repo.createPurchase(
      supplierId: id,
      lines: const [PurchaseLineInput(productId: 'a', productName: 'A', qty: 1, price: 5000)],
      paidNow: 5000,
      receivedBy: 'Vali',
      signaturePath: 's.png',
      userId: admin.id,
      userName: admin.fullName,
    );
    final m = (await repo.watchPayments(id).first).single;
    expect((m.receivedBy, m.signaturePath), ('Vali', 's.png'));
  });

  test("v2 baza yangilanganda imzo ustunlari qo'shiladi", () async {
    final dir = await Directory.systemTemp.createTemp('pos_mig2');
    final file = File('${dir.path}/db.sqlite');
    final db1 = AppDatabase(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    await db1.customStatement('ALTER TABLE supplier_payments DROP COLUMN received_by');
    await db1.customStatement('ALTER TABLE supplier_payments DROP COLUMN signature_path');
    await db1.customStatement('PRAGMA user_version = 2');
    await db1.close();

    final db2 = AppDatabase(NativeDatabase(file));
    final r = SupplierRepository(db2, () async => 'dev');
    final id = await r.saveSupplier(name: 'X');
    await r.addPayment(supplierId: id, amount: 1, signaturePath: 'a.png', userId: 'u', userName: 'U');
    expect((await r.watchPayments(id).first).single.signaturePath, 'a.png');
    await db2.close();
    await dir.delete(recursive: true);
  });

  test("yangilash yarim yo'lda qolgan bo'lsa ham baza ochiladi (ustun allaqachon bor)", () async {
    final dir = await Directory.systemTemp.createTemp('pos_mig3');
    final file = File('${dir.path}/db.sqlite');
    final db1 = AppDatabase(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    // received_by bor, signature_path yo'q, versiya esa hali 2.
    await db1.customStatement('ALTER TABLE supplier_payments DROP COLUMN signature_path');
    await db1.customStatement('PRAGMA user_version = 2');
    await db1.close();

    final db2 = AppDatabase(NativeDatabase(file));
    final r = SupplierRepository(db2, () async => 'dev');
    final id = await r.saveSupplier(name: 'Y');
    await r.addPayment(supplierId: id, amount: 1, receivedBy: 'A', signaturePath: 'b.png', userId: 'u', userName: 'U');
    expect((await r.watchPayments(id).first).single.signaturePath, 'b.png');
    await db2.close();
    await dir.delete(recursive: true);
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
