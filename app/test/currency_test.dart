import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/core/currency.dart';
import 'package:pos_terminal/core/formatters.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/currency_repository.dart';
import 'package:pos_terminal/data/repositories/supplier_repository.dart';
import 'package:pos_terminal/services/currency_service.dart';
import 'package:pos_terminal/services/printing/receipt_layout.dart';
import 'package:pos_terminal/state/cart.dart';

import 'test_helpers.dart';

void main() {
  late TestEnv env;
  late CurrencyRepository rates;
  late User admin;

  setUp(() async {
    env = TestEnv();
    rates = CurrencyRepository(env.db, () => env.settings.deviceId(), activity: env.activity);
    admin = await env.users.login('admin', 'admin123');
  });
  tearDown(() => env.close());

  Future<Product> usdProduct(double usd, int rate) async {
    final id = await env.products.save(ProductsCompanion(
      name: const Value('Sovun'),
      salePriceUsd: Value(usd),
      usdRate: Value(rate),
      salePrice: Value(Money.usdToSum(usd, rate)),
    ));
    return (await env.products.byId(id))!;
  }

  test("dollar narx so'mga yuqoriga yaxlitlanadi", () {
    expect(Money.usdToSum(0.60, 11700), 7100); // 7020 -> 7100
    expect(Money.usdToSum(0.60, 11700, step: 1), 7020);
    expect(Money.usdToSum(1, 12000), 12000); // aniq — oshirilmaydi
    expect(Money.usdToSum(0.5, 12345, step: 500), 6500);
    expect(Money.usd(1234.5), r'$1 234.50');
    expect(Money.fmt(1999, 'USD'), r'$19.99');
    expect(Money.fmt(1999, 'UZS'), "1 999 so'm");
    expect(Money.sumToCents(120000, 12000), 1000);
    expect(Money.centsToSum(1000, 12000), 120000);
  });

  test("kurs oshsa narx oshadi, tushsa — o'zgarmaydi", () async {
    final p = await usdProduct(1, 12000);
    expect(p.salePrice, 12000);

    // Kurs tushdi: narx 12 000 da qoladi.
    await rates.saveRate(rate: 11000);
    expect(await rates.applyRate(11000), 0);
    expect((await env.products.byId(p.id))!.salePrice, 12000);

    // Kurs 12 500 ga chiqdi: narx ham oshadi.
    await rates.saveRate(rate: 12500);
    expect(await rates.applyRate(12500), 1);
    final up = (await env.products.byId(p.id))!;
    expect(up.salePrice, 12500);
    expect(up.usdRate, 12500);
    expect(up.dirty, isTrue);

    // Yana tushdi — 12 500 da qoladi.
    await rates.applyRate(11800);
    expect((await env.products.byId(p.id))!.salePrice, 12500);

    // So'm narxli tovarga tegilmaydi.
    final plain = await env.addProduct('Chelak', price: 30000);
    await rates.applyRate(20000);
    expect((await env.products.byId(plain.id))!.salePrice, 30000);
  });

  test("joriy kurs — eng oxirgisi; MB kursi takror yozilmaydi", () async {
    expect(await rates.saveRate(rate: 12050.38, source: 'cbu', id: 'cbu-USD-2026-11-14', rateDate: '2026-11-14'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await rates.saveRate(rate: 12200, source: 'manual'), isTrue);
    // Tushdan keyin yana o'sha MB kursi keldi — qo'lda kiritilgan kurs ustidan yozmaydi.
    expect(await rates.saveRate(rate: 12050.38, source: 'cbu', id: 'cbu-USD-2026-11-14'), isFalse);
    expect((await rates.current())!.rate, 12200);
  });

  test('cbu.uz javobi o\'qiladi', () {
    final r = CurrencyService.parseCbu(
        '[{"id":69,"Code":"840","Ccy":"USD","Nominal":"1","Rate":"12050.38","Diff":"-12.5","Date":"14.11.2026"}]');
    expect(r!.rate, 12050.38);
    expect(r.date, '2026-11-14');
    expect(CurrencyService.slotOf(DateTime(2026, 11, 14, 7)), isNull);
    expect(CurrencyService.slotOf(DateTime(2026, 11, 14, 9)), '2026-11-14-am');
    expect(CurrencyService.slotOf(DateTime(2026, 11, 14, 15)), '2026-11-14-pm');
  });

  test("dollar va so'm aralash to'lov, chekda faqat so'm (sozlamaga qarab dollar ham)", () async {
    final p = await env.addProduct('Dazmol', price: 150000, stock: 5);
    final sale = await env.checkout.checkout(
      cart: CartState(lines: [CartLine(product: p, qty: 1)]),
      // 10$ x 12 000 = 120 000 + 40 000 naqd = 160 000 -> qaytim 10 000.
      payment: const PaymentInput(cash: 40000, usd: 10, usdRate: 12000),
      cashier: admin,
    );
    expect(sale.sale.paidUsd, 10);
    expect(sale.sale.usdRate, 12000);
    expect(sale.sale.changeAmount, 10000);
    expect(sale.sale.paymentType, PaymentType.cash.code);

    final summary = await env.stats.watchSummary(DayRange.today()).first;
    expect(summary.cash, 150000);
    expect(summary.usd, 10);

    final plain = ReceiptLayout.build(sale, const StoreInfo()).map((l) => l.text).join('\n');
    expect(plain.contains(r'$'), isFalse);
    expect(plain, contains('Dollar bilan:'));
    final withUsd = ReceiptLayout.build(sale, const StoreInfo(showUsd: true)).map((l) => l.text).join('\n');
    expect(withUsd, contains(r'$12.50')); // 150 000 / 12 000
    expect(withUsd, contains(r'$10.00'));
  });

  test("dollar qarzli mijoz: nasiya kurs bo'yicha dollarga yoziladi, qaytarilsa aynan o'sha summa", () async {
    final p = await env.addProduct('Gilam', price: 600000, stock: 2);
    final c = await env.customers.save(name: 'Botir', currency: Currency.usd.code);
    final sale = await env.checkout.checkout(
      cart: CartState(lines: [CartLine(product: p, qty: 1)]),
      payment: PaymentInput(debt: 600000, customerId: c.id, customerName: c.name, usdRate: 12000),
      cashier: admin,
    );
    expect(await env.customers.debtOf(c.id), 5000); // $50.00
    final summary = await env.customers.summaryOf(env.branch.id).first;
    expect(summary.totalDebt, 0);
    expect(summary.totalDebtUsd, 5000);

    await env.customers.addPayment(c.id, 1000, user: admin, usdRate: 12500); // $10
    expect(await env.customers.debtOf(c.id), 4000);

    // Kurs o'zgargan bo'lsa ham qaytarishda $50 ayriladi.
    await env.checkout.refund(sale, admin);
    expect(await env.customers.debtOf(c.id), -1000);

    // Daftarida yozuv bor — valyutani almashtirib bo'lmaydi.
    expect(() => env.customers.save(id: c.id, name: 'Botir', currency: Currency.uzs.code), throwsA(anything));
  });

  test('dollar firma: kirim, qarz va to\'lov sentda; xulosada alohida', () async {
    final repo = SupplierRepository(env.db, () => env.settings.deviceId());
    final usdFirm = await repo.saveSupplier(name: 'Import LLC', currency: Currency.usd.code);
    final uzsFirm = await repo.saveSupplier(name: 'Mahalliy');
    await repo.createPurchase(
      supplierId: usdFirm,
      lines: const [PurchaseLineInput(productId: 'a', productName: 'Sovun', qty: 100, price: 60)], // $0.60
      paidNow: 2000, // $20
      usdRate: 12000,
      userId: admin.id,
      userName: admin.fullName,
    );
    await repo.createPurchase(
      supplierId: uzsFirm,
      lines: const [PurchaseLineInput(productId: 'b', productName: 'Chelak', qty: 2, price: 50000)],
      userId: admin.id,
      userName: admin.fullName,
    );
    expect(await repo.balanceOf(usdFirm), 4000); // $40
    final s = await repo.watchSummary().first;
    expect(s.totalDebt, 100000);
    expect(s.totalDebtUsd, 4000);
    expect(s.paidTodayUsd, 2000);
    expect(s.paidToday, 0);
    expect(() => repo.saveSupplier(id: usdFirm, name: 'Import LLC', currency: 'UZS'), throwsA(anything));
  });
}
