import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/branch.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/core/formatters.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/branch_repository.dart';
import 'package:pos_terminal/data/repositories/sale_repository.dart';
import 'package:pos_terminal/data/repositories/stock_repository.dart';
import 'package:pos_terminal/services/checkout_service.dart';
import 'package:pos_terminal/state/cart.dart';

import 'test_helpers.dart';

void main() {
  late TestEnv env;
  late User admin;
  late BranchRepository branches;

  setUp(() async {
    env = TestEnv();
    admin = await env.users.login('admin', 'admin123');
    env.actor = admin;
    branches = BranchRepository(env.db, () => env.settings.deviceId());
  });

  tearDown(() => env.close());

  Future<void> switchTo(String id) async {
    env.branch.set(id);
    await env.stock.recompute();
  }

  test('asosiy filial avtomatik yaratiladi', () async {
    final list = await branches.all();
    expect(list.single.id, kDefaultBranchId);
  });

  test("qoldiq va savdo har bir filialda alohida, tovar umumiy", () async {
    final p = await env.addProduct('Chelak', price: 20000, stock: 10, barcode: '4780000000017');
    final b2 = await branches.save(name: 'Chilonzor');

    await switchTo(b2);
    expect((await env.products.byId(p.id))!.stockQty, 0);
    expect((await env.products.findByBarcode('4780000000017'))?.id, p.id);
    await env.stock.addMovements([MovementInput(productId: p.id, type: MovementType.receipt, qty: 3)],
        userId: admin.id, userName: admin.fullName);
    final fresh = (await env.products.byId(p.id))!;
    final sale = await env.checkout.checkout(
        cart: CartState(lines: [CartLine(product: fresh, qty: 1)]),
        payment: const PaymentInput(cash: 20000),
        cashier: admin);
    expect(sale.sale.branchId, b2);
    expect((await env.products.byId(p.id))!.stockQty, 2);
    expect((await env.stats.watchSummary(DayRange.today()).first).total, 20000);

    await switchTo(kDefaultBranchId);
    expect((await env.products.byId(p.id))!.stockQty, 10);
    expect((await env.stats.watchSummary(DayRange.today()).first).total, 0);
    expect(await env.sales.watchSales(const SaleFilter()).first, isEmpty);
    expect(await env.stock.stockByBranch(p.id), {kDefaultBranchId: 10, b2: 2});

    // Boshqa filialdagi chekni qaytarish o'sha filial qoldig'iga qaytadi.
    await env.checkout.refund(sale, admin);
    expect((await env.products.byId(p.id))!.stockQty, 10);
    expect((await env.stock.stockByBranch(p.id))[b2], 3);
  });

  test('filial oqimlari filial almashganda qayta quriladi', () async {
    final p = await env.addProduct('Tova', price: 5000, stock: 5);
    final b2 = await branches.save(name: 'Yunusobod');
    final seen = <int>[];
    final sub = env.stats.watchSummary(DayRange.today()).listen((s) => seen.add(s.total));
    await env.checkout.checkout(
        cart: CartState(lines: [CartLine(product: p, qty: 1)]), payment: const PaymentInput(cash: 5000), cashier: admin);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await switchTo(b2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await sub.cancel();
    expect(seen.last, 0);
    expect(seen, contains(5000));
  });

  test('ruxsatlar filial bo\'yicha', () async {
    final b2 = await branches.save(name: 'Sergeli');
    await env.users.save(
      username: 'kassir2',
      fullName: 'Kassir Ikki',
      role: UserRole.cashier,
      password: '1234',
      branchRoles: {b2: UserRole.admin.code},
    );
    final u = await env.users.login('kassir2', '1234');
    expect(u.roleIn(b2), UserRole.admin);
    expect(u.roleIn(kDefaultBranchId), isNull);
    expect(u.isOwner, isFalse);
    expect(admin.isOwner, isTrue);
    expect(admin.roleIn(b2), UserRole.admin);

    // Faqat b2 da admin: asosiy filialda 20% dan katta chegirmani tasdiqlay olmaydi.
    final p = await env.addProduct('Qozon', price: 100000, stock: 5);
    final cart = CartState(
        lines: [CartLine(product: p, qty: 1)], discountType: DiscountType.percent, discountValue: 30, discountApprovedBy: u);
    expect(() => env.checkout.checkout(cart: cart, payment: const PaymentInput(cash: 70000), cashier: u),
        throwsA(isA<CheckoutException>()));

    // Oxirgi bosh adminni oddiy xodimga aylantirib bo'lmaydi.
    expect(
      () => env.users.save(id: admin.id, username: 'admin', fullName: 'A', role: UserRole.admin, branchRoles: {b2: 'admin'}),
      throwsA(anything),
    );
  });

  test("o'zgarishlar jurnali: qo'shilgan, o'zgargan, o'chirilgan tovar va ombor harakatlari", () async {
    final p = await env.addProduct('Supurgi', price: 15000, stock: 4);
    await env.products.save(ProductsCompanion(id: Value(p.id), name: const Value('Supurgi'), salePrice: const Value(17000)));
    await env.stock.addMovements([MovementInput(productId: p.id, type: MovementType.writeOff, qty: -1, note: 'singan')],
        userId: admin.id, userName: admin.fullName);
    final q = await env.addProduct('Paqir');
    await env.products.softDelete(q.id);

    final day = await env.activity.load(DayRange.today(), env.branch.id);
    expect(day.productsAdded, 1); // Paqir o'chirildi
    expect(day.productsDeleted, 1);
    expect(day.priceChanges, 1);
    expect(day.receiptCount, 1);
    expect(day.writeOffCount, 1);
    expect(day.writeOffQty, 1);
    final actions = day.entries.map((e) => e.action).toSet();
    expect(actions, containsAll(['product_created', 'price_changed', 'product_deleted', 'stock_writeoff', 'login']));
    expect(day.entries.firstWhere((e) => e.action == 'price_changed').details, contains('17 000'));

    // Boshqa filialda: tovar o'zgarishlari (umumiy) ko'rinadi, ombor harakatlari — yo'q.
    final b2 = await branches.save(name: 'B2');
    final other = await env.activity.load(DayRange.today(), b2);
    expect(other.writeOffCount, 0);
    expect(other.entries.map((e) => e.action), contains('product_created'));
  });

  test("v3 baza yangilanganda eski savdo va qoldiq asosiy filialga o'tadi", () async {
    final dir = await Directory.systemTemp.createTemp('pos_mig4');
    final file = File('${dir.path}/db.sqlite');
    final db1 = AppDatabase(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    await db1.customStatement(
        "INSERT INTO stock_movements (id, product_id, type, qty, created_at, updated_at) VALUES ('m1', 'p1', 'receipt', 5, 1, 1)");
    await db1.customStatement('DROP INDEX idx_sales_branch');
    await db1.customStatement('DROP INDEX idx_movements_branch');
    for (final (t, c) in [
      ('sales', 'branch_id'),
      ('stock_movements', 'branch_id'),
      ('audit_log', 'branch_id'),
      ('audit_log', 'ref_id'),
      ('supplier_purchases', 'branch_id'),
      ('supplier_payments', 'branch_id'),
      ('users', 'branch_roles'),
    ]) {
      await db1.customStatement('ALTER TABLE $t DROP COLUMN $c');
    }
    await db1.customStatement('DROP TABLE branches');
    await db1.customStatement('PRAGMA user_version = 3');
    await db1.close();

    for (var i = 0; i < 2; i++) {
      final db2 = AppDatabase(NativeDatabase(file));
      final m = await db2.select(db2.stockMovements).getSingle();
      expect(m.branchId, kDefaultBranchId);
      expect((await db2.select(db2.branches).get()).single.id, kDefaultBranchId);
      expect((await db2.select(db2.users).get()).first.branchRoles, '');
      await db2.close();
      if (i == 0) {
        // Yangilash yarim yo'lda qolgan holat: versiya qaytariladi, ustunlar esa bor.
        final db3 = AppDatabase(NativeDatabase(file));
        await db3.customSelect('SELECT 1').get();
        await db3.customStatement('PRAGMA user_version = 3');
        await db3.close();
      }
    }
    await dir.delete(recursive: true);
  });
}
