import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/core/formatters.dart';
import 'package:pos_terminal/core/season.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/services/checkout_service.dart';
import 'package:pos_terminal/state/cart.dart';

import 'test_helpers.dart';

void main() {
  late TestEnv env;
  late User admin;
  late User cashier;

  setUp(() async {
    env = TestEnv();
    admin = await env.users.login('admin', 'admin123');
    await env.users.save(username: 'kassir1', fullName: 'Kassir Bir', role: UserRole.cashier, password: '1234');
    cashier = await env.users.login('kassir1', '1234');
  });

  tearDown(() => env.close());

  test('sotuv: qoldiq kamayadi, chek raqami, mavsumiy statistika', () async {
    final p = await env.addProduct('Chelak', price: 25000, cost: 16000, stock: 10, min: 3, barcode: '4780000000017');
    final found = await env.products.findByBarcode('4780000000017');
    expect(found?.id, p.id);

    final cart = CartState(lines: [CartLine(product: p, qty: 2)]);
    final s = await env.checkout.checkout(cart: cart, payment: const PaymentInput(cash: 60000), cashier: cashier);
    expect(s.sale.total, 50000);
    expect(s.sale.changeAmount, 10000);
    expect(s.sale.receiptNo, 'K1-000001');
    expect(s.sale.costTotal, 32000);
    expect((await env.products.byId(p.id))!.stockQty, 8);

    final season = Season.current;
    final stats = await env.db.select(env.db.seasonalStats).get();
    expect(stats.single.season, season.index0);
    expect(stats.single.qty, 2);

    final s2 = await env.checkout.checkout(cart: cart, payment: const PaymentInput(card: 50000), cashier: cashier);
    expect(s2.sale.receiptNo, 'K1-000002');
    expect(s2.sale.paymentType, PaymentType.card.code);
  });

  test('kam qoldiq alerti yaratiladi va takrorlanmaydi', () async {
    final p = await env.addProduct('Tova', stock: 5, min: 3);
    final cart = CartState(lines: [CartLine(product: p, qty: 2)]);
    await env.checkout.checkout(cart: cart, payment: const PaymentInput(cash: 20000), cashier: cashier);
    final cart2 = CartState(lines: [CartLine(product: p, qty: 1)]);
    await env.checkout.checkout(cart: cart2, payment: const PaymentInput(cash: 10000), cashier: cashier);
    final alerts = await env.db.select(env.db.alerts).get();
    expect(alerts.where((a) => a.type == AlertType.lowStock.code).length, 1);
  });

  test('kassir 20% dan yuqori chegirma bera olmaydi, admin tasdig\'i bilan mumkin', () async {
    final p = await env.addProduct('Qozon', price: 100000, stock: 5);
    final cart = CartState(lines: [CartLine(product: p, qty: 1)], discountType: DiscountType.percent, discountValue: 25);
    expect(
      () => env.checkout.checkout(cart: cart, payment: const PaymentInput(cash: 100000), cashier: cashier),
      throwsA(isA<CheckoutException>()),
    );
    // Summa ko'rinishidagi 21% ham bloklanadi.
    final cartAmt = CartState(lines: [CartLine(product: p, qty: 1)], discountType: DiscountType.amount, discountValue: 21000);
    expect(
      () => env.checkout.checkout(cart: cartAmt, payment: const PaymentInput(cash: 100000), cashier: cashier),
      throwsA(isA<CheckoutException>()),
    );
    // 20% — ruxsat.
    final ok = CartState(lines: [CartLine(product: p, qty: 1)], discountType: DiscountType.percent, discountValue: 20);
    final s = await env.checkout.checkout(cart: ok, payment: const PaymentInput(cash: 80000), cashier: cashier);
    expect(s.sale.total, 80000);
    // Admin tasdig'i bilan 25%.
    final approved = cart.copyWith(discountApprovedBy: () => admin);
    final s2 = await env.checkout.checkout(cart: approved, payment: const PaymentInput(cash: 75000), cashier: cashier);
    expect(s2.sale.discountApprovedBy, admin.id);
  });

  test("to'lov yetarli bo'lmasa xato; aralash to'lov", () async {
    final p = await env.addProduct('Lampa', price: 22000, stock: 50);
    final cart = CartState(lines: [CartLine(product: p, qty: 3)]);
    expect(
      () => env.checkout.checkout(cart: cart, payment: const PaymentInput(cash: 10000), cashier: cashier),
      throwsA(isA<CheckoutException>()),
    );
    expect(
      () => env.checkout.checkout(cart: cart, payment: const PaymentInput(card: 70000), cashier: cashier),
      throwsA(isA<CheckoutException>()),
    );
    final s = await env.checkout.checkout(
        cart: cart, payment: const PaymentInput(cash: 30000, card: 20000, transfer: 16000), cashier: cashier);
    expect(s.sale.paymentType, PaymentType.mixed.code);
    expect(s.sale.changeAmount, 0);
  });

  test('qaytarish: tovar omborga qaytadi, statistika kamayadi, faqat admin', () async {
    final p = await env.addProduct('Adyol', price: 300000, stock: 4);
    final s = await env.checkout.checkout(
        cart: CartState(lines: [CartLine(product: p, qty: 2)]), payment: const PaymentInput(cash: 600000), cashier: cashier);
    expect(() => env.checkout.refund(s, cashier), throwsA(isA<CheckoutException>()));
    await env.checkout.refund(s, admin);
    expect((await env.products.byId(p.id))!.stockQty, 4);
    final sale = (await env.sales.getWithItems(s.sale.id))!.sale;
    expect(sale.status, SaleStatus.refunded.code);
    final stats = await env.db.select(env.db.seasonalStats).get();
    expect(stats.single.qty, 0);
    // Qayta qurish ham bir xil natija beradi.
    await env.stats.rebuildSeasonal();
    expect(await env.db.select(env.db.seasonalStats).get(), isEmpty);
  });

  test('statistika: tez sotiladigan va mavsumiy tavsiyalar real-time', () async {
    final a = await env.addProduct('A', stock: 100);
    final b = await env.addProduct('B', stock: 100, seasons: Season.current.code);
    final stream = env.stats.watchFrequent(days: 7);
    expect(await stream.first, isEmpty);
    for (var i = 0; i < 3; i++) {
      await env.checkout.checkout(
          cart: CartState(lines: [CartLine(product: a, qty: 1)]), payment: const PaymentInput(cash: 10000), cashier: cashier);
    }
    final freq = await env.stats.watchFrequent(days: 7).first;
    expect(freq.first.productId, a.id);
    expect(freq.first.receipts, 3);
    final seasonal = await env.stats.watchSeasonal(Season.current).first;
    expect(seasonal.map((e) => e.productId), containsAll([a.id, b.id]));
    expect(seasonal.firstWhere((e) => e.productId == b.id).fromTagOnly, isTrue);
    final summary = await env.stats.watchSummary(DayRange.today()).first;
    expect(summary.count, 3);
    expect(summary.total, 30000);
  });
}
