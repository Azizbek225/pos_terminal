import '../data/database.dart';

/// Chegirma turi.
enum DiscountType { none, percent, amount }

/// Savatdagi bitta qator.
class CartLine {
  const CartLine({required this.product, required this.qty});

  final Product product;
  final double qty;

  int get price => product.salePrice;

  /// Qator summasi (chegirmasiz), so'mga yaxlitlangan.
  int get gross => (qty * price).round();

  CartLine copyWith({double? qty, Product? product}) =>
      CartLine(product: product ?? this.product, qty: qty ?? this.qty);
}

/// Savat holati — o'zgarmas (immutable) obyekt; har o'zgarishda yangisi yaratiladi.
class CartState {
  const CartState({
    this.lines = const [],
    this.discountType = DiscountType.none,
    this.discountValue = 0,
    this.discountApprovedBy,
  });

  final List<CartLine> lines;
  final DiscountType discountType;

  /// Foiz (1..100) yoki summa (so'm).
  final double discountValue;

  /// 20% dan yuqori chegirmani tasdiqlagan Admin.
  final User? discountApprovedBy;

  bool get isEmpty => lines.isEmpty;

  int get subtotal => lines.fold(0, (s, l) => s + l.gross);

  double get itemCount => lines.fold(0.0, (s, l) => s + l.qty);

  int get discountAmount {
    final sub = subtotal;
    if (sub <= 0) return 0;
    switch (discountType) {
      case DiscountType.none:
        return 0;
      case DiscountType.percent:
        return (sub * discountValue / 100).round().clamp(0, sub);
      case DiscountType.amount:
        return discountValue.round().clamp(0, sub);
    }
  }

  /// Chegirmaning foizdagi ekvivalenti (summa chegirmasi uchun ham) —
  /// rol cheklovini tekshirishda ishlatiladi.
  double get discountPercentEquivalent {
    final sub = subtotal;
    if (sub <= 0) return 0;
    return discountAmount * 100 / sub;
  }

  int get total => subtotal - discountAmount;

  /// Chek chegirmasini qatorlarga proporsional taqsimlash
  /// (qoldiq oxirgi qatorga qo'shiladi — yig'indi aniq mos keladi).
  List<int> allocateDiscount() {
    final d = discountAmount;
    final sub = subtotal;
    if (d == 0 || sub == 0) return List.filled(lines.length, 0);
    final result = <int>[];
    var used = 0;
    for (var i = 0; i < lines.length; i++) {
      if (i == lines.length - 1) {
        result.add(d - used);
      } else {
        final part = (d * lines[i].gross / sub).floor();
        result.add(part);
        used += part;
      }
    }
    return result;
  }

  CartState copyWith({
    List<CartLine>? lines,
    DiscountType? discountType,
    double? discountValue,
    User? Function()? discountApprovedBy,
  }) =>
      CartState(
        lines: lines ?? this.lines,
        discountType: discountType ?? this.discountType,
        discountValue: discountValue ?? this.discountValue,
        discountApprovedBy: discountApprovedBy != null ? discountApprovedBy() : this.discountApprovedBy,
      );
}

/// To'lov ma'lumoti.
class PaymentInput {
  const PaymentInput({this.cash = 0, this.card = 0, this.transfer = 0});

  final int cash;
  final int card;
  final int transfer;

  int get totalPaid => cash + card + transfer;
}
