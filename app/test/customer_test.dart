import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/core/formatters.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/services/checkout_service.dart';
import 'package:pos_terminal/state/cart.dart';

import 'test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() => env = TestEnv());
  tearDown(() => env.close());

  test('nasiya savdo: qisman to\'lov, qolgani mijoz qarziga', () async {
    final admin = await env.users.login('admin', 'admin123');
    final p = await env.addProduct('Chelak', price: 50000, stock: 10);
    final c = await env.customers.save(name: 'Anvar aka', phone: '+998901234567');

    final sale = await env.checkout.checkout(
      cart: CartState(lines: [CartLine(product: p, qty: 2)]),
      payment: PaymentInput(cash: 30000, debt: 70000, customerId: c.id, customerName: c.name),
      cashier: admin,
    );
    expect(sale.sale.paymentType, PaymentType.debt.code);
    expect(sale.sale.debtAmount, 70000);
    expect(sale.sale.customerName, 'Anvar aka');
    expect(await env.customers.debtOf(c.id), 70000);

    // Monitoring: nasiya qismi daromadga qo'shilmaydi.
    final today = await env.stats.summaryOf(DayRange.today(), env.branch.id).first;
    expect(today.total, 100000);
    expect(today.debt, 70000);
    expect(today.collected, 30000);
    expect((await env.customers.summaryOf(env.branch.id).first).totalDebt, 70000);

    // Qarz to'lovi va qo'lda yozilgan eski qarz.
    await env.customers.addPayment(c.id, 20000, user: admin);
    await env.customers.addManualDebt(c.id, 15000, note: 'daftardan', user: admin);
    expect(await env.customers.debtOf(c.id), 65000);

    final ledger = await env.customers.watchLedger(c.id).first;
    expect(ledger.map((e) => e.kind), [CustomerDebtKind.manual, CustomerDebtKind.payment, CustomerDebtKind.sale]);
    expect(ledger.first.balance, 65000);
    expect(ledger.last.receiptNo, sale.sale.receiptNo);

    final balances = await env.customers.watchBalances().first;
    expect(balances.single.debt, 65000);
    final summary = await env.customers.watchSummary().first;
    expect(summary.totalDebt, 65000);
    expect(summary.debtorCount, 1);
    expect(summary.paidToday, 20000);
    expect(summary.debtToday, 70000);

    // Chek qaytarilsa — nasiya qismi qarzdan chiqadi.
    await env.checkout.refund(sale, admin);
    expect(await env.customers.debtOf(c.id), -5000);

    // Qarzi bor/avansli mijoz o'chirilmaydi.
    expect(() => env.customers.delete(c.id), throwsA(anything));
  });

  test('nasiya: mijozsiz yoki yetmaydigan summa rad etiladi', () async {
    final admin = await env.users.login('admin', 'admin123');
    final p = await env.addProduct('Supurgi', price: 20000, stock: 5);
    final cart = CartState(lines: [CartLine(product: p, qty: 1)]);
    expect(
      () => env.checkout.checkout(cart: cart, payment: const PaymentInput(debt: 20000), cashier: admin),
      throwsA(isA<CheckoutException>()),
    );
    final c = await env.customers.save(name: 'Dilnoza');
    expect(
      () => env.checkout.checkout(
          cart: cart, payment: PaymentInput(cash: 5000, debt: 10000, customerId: c.id), cashier: admin),
      throwsA(isA<CheckoutException>()),
    );
    final s = await env.checkout.checkout(
        cart: cart, payment: PaymentInput(debt: 20000, customerId: c.id, customerName: c.name), cashier: admin);
    expect(s.sale.paidCash, 0);
    expect(await env.customers.debtOf(c.id), 20000);
  });

  test('v4 baza v5 ga yangilanadi (qayta bajarilsa ham xato bermaydi)', () async {
    final dir = await Directory.systemTemp.createTemp('pos_mig5');
    final file = File('${dir.path}/db.sqlite');
    final db1 = AppDatabase(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    await db1.customStatement('DROP INDEX idx_customer_debts_customer');
    await db1.customStatement('DROP TABLE customer_debts');
    await db1.customStatement('DROP TABLE customers');
    for (final c in ['debt_amount', 'customer_id', 'customer_name']) {
      await db1.customStatement('ALTER TABLE sales DROP COLUMN $c');
    }
    await db1.customStatement('PRAGMA user_version = 4');
    await db1.close();

    for (var i = 0; i < 2; i++) {
      final db2 = AppDatabase(NativeDatabase(file));
      expect(await db2.select(db2.customers).get(), isEmpty);
      expect(await db2.select(db2.customerDebts).get(), isEmpty);
      await db2.customSelect('SELECT debt_amount, customer_id, customer_name FROM sales').get();
      await db2.close();
      if (i == 0) {
        final db3 = AppDatabase(NativeDatabase(file));
        await db3.customSelect('SELECT 1').get();
        await db3.customStatement('PRAGMA user_version = 4');
        await db3.close();
      }
    }
    await dir.delete(recursive: true);
  });
}
