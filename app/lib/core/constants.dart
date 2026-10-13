/// Butun ilova bo'ylab ishlatiladigan doimiy qiymatlar va enumlar.
///
/// Ma'lumotlar bazasida enumlar matn (String) ko'rinishida saqlanadi —
/// bu sinxronlash serveri va boshqa qurilmalar bilan moslikni osonlashtiradi.
library;

/// Foydalanuvchi rollari.
enum UserRole {
  admin('admin', 'Admin'),
  cashier('cashier', 'Kassir'),
  storekeeper('storekeeper', 'Omborchi');

  const UserRole(this.code, this.label);
  final String code;
  final String label;

  static UserRole fromCode(String code) =>
      UserRole.values.firstWhere((r) => r.code == code, orElse: () => UserRole.cashier);
}

/// To'lov turlari.
enum PaymentType {
  cash('cash', 'Naqd'),
  card('card', 'Karta'),
  transfer('transfer', "O'tkazma"),
  mixed('mixed', 'Aralash');

  const PaymentType(this.code, this.label);
  final String code;
  final String label;

  static PaymentType fromCode(String code) =>
      PaymentType.values.firstWhere((p) => p.code == code, orElse: () => PaymentType.cash);
}

/// Chek holati.
enum SaleStatus {
  completed('completed', 'Yakunlangan'),
  refunded('refunded', 'Qaytarilgan');

  const SaleStatus(this.code, this.label);
  final String code;
  final String label;

  static SaleStatus fromCode(String code) =>
      SaleStatus.values.firstWhere((s) => s.code == code, orElse: () => SaleStatus.completed);
}

/// Ombor harakati turlari. `qty` har doim ishorali saqlanadi:
/// kirim musbat, chiqim manfiy.
enum MovementType {
  receipt('receipt', 'Kirim', 1),
  sale('sale', 'Sotuv', -1),
  customerReturn('customer_return', 'Mijoz qaytardi', 1),
  writeOff('writeoff', 'Hisobdan chiqarish', -1),
  supplierReturn('supplier_return', "Yetkazib beruvchiga qaytarish", -1),
  adjustment('adjustment', "Inventarizatsiya tuzatish", 0);

  const MovementType(this.code, this.label, this.sign);
  final String code;
  final String label;

  /// +1 kirim, -1 chiqim, 0 — ishora foydalanuvchi kiritgan qiymatdan olinadi.
  final int sign;

  static MovementType fromCode(String code) =>
      MovementType.values.firstWhere((m) => m.code == code, orElse: () => MovementType.adjustment);
}

/// Firma bilan hisob-kitob hujjati turi.
enum PurchaseKind {
  purchase('purchase', 'Kirim'),
  opening('opening', "Boshlang'ich qarz"),

  /// Kam kelgan / firmaga qaytarilgan tovar: `total` manfiy, qarzni kamaytiradi
  /// (qarz manfiyga o'tsa — firma sizga qarz).
  credit('credit', 'Kam kelgan / qaytarilgan tovar');

  const PurchaseKind(this.code, this.label);
  final String code;
  final String label;

  static PurchaseKind fromCode(String code) =>
      PurchaseKind.values.firstWhere((k) => k.code == code, orElse: () => PurchaseKind.purchase);
}

/// Alert turlari.
enum AlertType {
  lowStock('low_stock', 'Kam qoldiq'),
  outOfStock('out_of_stock', 'Tovar tugadi'),
  dailyTarget('daily_target', 'Kunlik maqsad'),
  anomaly('anomaly', 'Anomal savdo'),
  sync('sync', 'Sinxronlash'),
  system('system', 'Tizim');

  const AlertType(this.code, this.label);
  final String code;
  final String label;

  static AlertType fromCode(String code) =>
      AlertType.values.firstWhere((a) => a.code == code, orElse: () => AlertType.system);
}

enum AlertSeverity {
  info('info', "Ma'lumot"),
  warning('warning', 'Ogohlantirish'),
  critical('critical', 'Jiddiy');

  const AlertSeverity(this.code, this.label);
  final String code;
  final String label;

  static AlertSeverity fromCode(String code) =>
      AlertSeverity.values.firstWhere((a) => a.code == code, orElse: () => AlertSeverity.info);
}

/// Standart o'lchov birliklari (O'zbekiston soliq tizimidagi
/// "o'lchov birligi kodi" bilan moslashtirilgan qisqa nomlar).
const kUnits = <String>[
  'dona',
  'kg',
  'gramm',
  'litr',
  'metr',
  'm²',
  'quti',
  'juft',
  "to'plam",
  'rulon',
  'paket',
];

/// Rol bo'yicha kassir bera oladigan maksimal chegirma (%).
/// Undan yuqori chegirmani faqat Admin tasdiqlaydi.
const double kCashierMaxDiscountPercent = 20;

/// Chegirmaning absolyut yuqori chegarasi (Admin uchun ham).
const double kAbsoluteMaxDiscountPercent = 100;

/// Sinxronlanadigan jadval (entity) nomlari — server bilan bir xil bo'lishi shart.
class SyncEntities {
  static const users = 'users';
  static const categories = 'categories';
  static const products = 'products';
  static const sales = 'sales';
  static const saleItems = 'sale_items';
  static const stockMovements = 'stock_movements';
  static const auditLog = 'audit_log';
  static const suppliers = 'suppliers';
  static const supplierPurchases = 'supplier_purchases';
  static const supplierPurchaseItems = 'supplier_purchase_items';
  static const supplierPayments = 'supplier_payments';

  static const all = [
    users,
    categories,
    products,
    sales,
    saleItems,
    stockMovements,
    auditLog,
    suppliers,
    supplierPurchases,
    supplierPurchaseItems,
    supplierPayments,
  ];
}
