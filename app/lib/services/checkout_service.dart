import '../core/branch.dart';
import '../core/constants.dart';
import '../core/security.dart';
import '../data/database.dart';
import '../data/repositories/customer_repository.dart';
import '../data/repositories/sale_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/stats_repository.dart';
import '../data/repositories/stock_repository.dart';
import '../data/repositories/user_repository.dart';
import '../state/cart.dart';
import 'alert_service.dart';

class CheckoutException implements Exception {
  CheckoutException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Savdoni yakunlash: chek, qatorlar, ombor harakatlari, mavsumiy statistika
/// va alertlar — barchasi bitta atomar tranzaksiyada.
class CheckoutService {
  CheckoutService({
    required this.db,
    required this.settings,
    required this.stock,
    required this.sales,
    required this.stats,
    required this.users,
    required this.alerts,
    this.customers,
  });

  final AppDatabase db;
  final SettingsRepository settings;
  final StockRepository stock;
  final SaleRepository sales;
  final StatsRepository stats;
  final UserRepository users;
  final AlertService alerts;
  final CustomerRepository? customers;

  /// To'lov turini kiritilgan summalardan aniqlash.
  static PaymentType resolvePaymentType(PaymentInput p) {
    if (p.debt > 0) return PaymentType.debt;
    final parts = [p.cash > 0, p.card > 0, p.transfer > 0].where((x) => x).length;
    if (parts > 1) return PaymentType.mixed;
    if (p.card > 0) return PaymentType.card;
    if (p.transfer > 0) return PaymentType.transfer;
    return PaymentType.cash;
  }

  /// Chegirma qoidalarini tekshirish:
  /// * Kassir/Omborchi — maksimal 20%.
  /// * 20% dan yuqori — faqat Admin (o'zi yoki tasdiqlovchi Admin).
  void validateDiscount(CartState cart, User cashier) => validateDiscountIn(cart, cashier, stock.branch.id);

  static void validateDiscountIn(CartState cart, User cashier, String branchId) {
    final pct = cart.discountPercentEquivalent;
    if (pct > kAbsoluteMaxDiscountPercent) {
      throw CheckoutException("Chegirma 100% dan oshmasligi kerak");
    }
    if (pct > kCashierMaxDiscountPercent + 0.0001) {
      final isAdmin = cashier.roleIn(branchId) == UserRole.admin;
      final approved = cart.discountApprovedBy != null && cart.discountApprovedBy!.roleIn(branchId) == UserRole.admin;
      if (!isAdmin && !approved) {
        throw CheckoutException("20% dan yuqori chegirmani faqat Admin bera oladi");
      }
    }
  }

  Future<SaleWithItems> checkout({
    required CartState cart,
    required PaymentInput payment,
    required User cashier,
    String note = '',
  }) async {
    if (cart.isEmpty) throw CheckoutException("Savat bo'sh");
    if (cart.lines.any((l) => l.qty <= 0)) throw CheckoutException("Miqdor 0 dan katta bo'lishi kerak");
    validateDiscount(cart, cashier);

    final total = cart.total;
    if (payment.card + payment.transfer > total) {
      throw CheckoutException("Karta/o'tkazma summasi chek summasidan oshmasligi kerak");
    }
    if (payment.debt < 0 || payment.debt > total) throw CheckoutException("Qarz summasi noto'g'ri");
    if (payment.debt > 0 && (payment.customerId.isEmpty || customers == null)) {
      throw CheckoutException('Nasiya uchun mijozni tanlang');
    }
    if (payment.covered < total) {
      throw CheckoutException("To'lov yetarli emas");
    }
    final change = payment.covered - total; // Qaytim faqat naqddan beriladi
    if (change > payment.cash) throw CheckoutException("Qaytim naqd summadan oshib ketdi");

    final dev = await settings.deviceId();
    final now = Ids.nowMs();
    final saleId = Ids.newId();
    final discounts = cart.allocateDiscount();
    final costTotal = cart.lines.fold<int>(0, (s, l) => s + (l.qty * l.product.purchasePrice).round());

    late Sale sale;
    final items = <SaleItem>[];
    await db.transaction(() async {
      final receiptNo = await settings.nextReceiptNo();
      sale = Sale(
        id: saleId,
        receiptNo: receiptNo,
        cashierId: cashier.id,
        cashierName: cashier.fullName,
        subtotal: cart.subtotal,
        discountType: cart.discountType.name,
        discountValue: cart.discountValue,
        discountAmount: cart.discountAmount,
        discountApprovedBy: cart.discountApprovedBy?.id,
        total: total,
        paymentType: resolvePaymentType(payment).code,
        paidCash: payment.cash,
        paidCard: payment.card,
        paidTransfer: payment.transfer,
        changeAmount: change,
        itemCount: cart.itemCount,
        costTotal: costTotal,
        status: SaleStatus.completed.code,
        note: note,
        createdAt: now,
        updatedAt: now,
        version: 1,
        deviceId: dev,
        isDeleted: false,
        dirty: true,
        branchId: stock.branch.id,
        debtAmount: payment.debt,
        customerId: payment.customerId,
        customerName: payment.customerName,
      );
      await db.into(db.sales).insert(sale);
      if (payment.debt > 0) {
        await customers!.addEntry(
          customerId: payment.customerId,
          kind: CustomerDebtKind.sale,
          amount: payment.debt,
          saleId: saleId,
          note: receiptNo,
          user: cashier,
        );
      }

      for (var i = 0; i < cart.lines.length; i++) {
        final l = cart.lines[i];
        final item = SaleItem(
          id: Ids.newId(),
          saleId: saleId,
          productId: l.product.id,
          productName: l.product.shortName.isNotEmpty ? l.product.shortName : l.product.name,
          barcode: l.product.barcode,
          unit: l.product.unit,
          qty: l.qty,
          price: l.price,
          purchasePrice: l.product.purchasePrice,
          discountAmount: discounts[i],
          lineTotal: l.gross - discounts[i],
          createdAt: now + i, // tartibni saqlash uchun
          updatedAt: now,
          version: 1,
          deviceId: dev,
          isDeleted: false,
          dirty: true,
        );
        await db.into(db.saleItems).insert(item);
        items.add(item);
        await stats.addToSeasonal(
          productId: l.product.id,
          at: DateTime.fromMillisecondsSinceEpoch(now),
          qty: l.qty,
          revenue: item.lineTotal,
        );
      }

      await stock.addMovements(
        [
          for (final l in cart.lines)
            MovementInput(
              productId: l.product.id,
              type: MovementType.sale,
              qty: -l.qty,
              unitCost: l.product.purchasePrice,
              refId: saleId,
              note: sale.receiptNo,
            ),
        ],
        userId: cashier.id,
        userName: cashier.fullName,
      );

      if (cart.discountApprovedBy != null) {
        await users.log(cart.discountApprovedBy!, 'discount_approved',
            '${sale.receiptNo}: ${cart.discountPercentEquivalent.toStringAsFixed(1)}% (${cart.discountAmount} so\'m)');
      }
    });

    // Tranzaksiyadan keyin — alertlar (xatolik savdoni bekor qilmasligi kerak).
    try {
      await alerts.checkStock(cart.lines.map((l) => l.product.id));
      await alerts.checkAnomaly(sale);
    } catch (_) {}

    return SaleWithItems(sale, items);
  }

  /// Chekni to'liq qaytarish: tovarlar omborga qaytadi, statistika kamayadi.
  Future<void> refund(SaleWithItems s, User by, {String reason = ''}) async {
    if (by.roleIn(s.sale.branchId) != UserRole.admin) {
      throw CheckoutException('Qaytarishni faqat Admin amalga oshiradi');
    }
    if (s.sale.status == SaleStatus.refunded.code) {
      throw CheckoutException('Bu chek allaqachon qaytarilgan');
    }
    await db.transaction(() async {
      await sales.markRefunded(s.sale, by);
      if (s.sale.debtAmount > 0 && s.sale.customerId.isNotEmpty && customers != null) {
        // Nasiyaga yozilgan qism mijoz qarzidan chiqariladi.
        await customers!.addEntry(
          customerId: s.sale.customerId,
          kind: CustomerDebtKind.refund,
          amount: -s.sale.debtAmount,
          saleId: s.sale.id,
          note: s.sale.receiptNo,
          user: by,
          branchId: s.sale.branchId,
        );
      }
      await stock.addMovements(
        [
          for (final i in s.items)
            MovementInput(
              productId: i.productId,
              type: MovementType.customerReturn,
              qty: i.qty,
              unitCost: i.purchasePrice,
              refId: s.sale.id,
              note: '${s.sale.receiptNo} ${reason.isEmpty ? '' : '— $reason'}',
            ),
        ],
        userId: by.id,
        userName: by.fullName,
        branchId: s.sale.branchId,
      );
      final at = DateTime.fromMillisecondsSinceEpoch(s.sale.createdAt);
      for (final i in s.items) {
        await stats.addToSeasonal(productId: i.productId, at: at, qty: -i.qty, revenue: -i.lineTotal, saleCount: -1);
      }
      await users.log(by, 'refund', '${s.sale.receiptNo}: ${s.sale.total} so\'m. $reason');
    });
    try {
      await alerts.checkStock(s.items.map((i) => i.productId));
    } catch (_) {}
  }
}
