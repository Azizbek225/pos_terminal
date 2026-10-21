import 'package:drift/drift.dart';

import '../../core/branch.dart';
import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/security.dart';
import '../database.dart';

/// O'zgarishlar jurnalidagi yozuv guruhi (filtr va ikonka uchun).
enum ActivityKind {
  product('Tovarlar'),
  stock('Ombor'),
  sale('Savdo'),
  supplier('Firmalar'),
  staff('Xodimlar va filiallar'),
  other('Boshqa');

  const ActivityKind(this.label);
  final String label;
}

/// Audit amallari nomi. Yangi amal qo'shilsa — shu yerga ham.
const kActivityLabels = <String, String>{
  'login': 'Tizimga kirish',
  'discount_approved': 'Chegirma tasdiqlandi',
  'refund': 'Chek qaytarildi',
  'product_created': "Yangi tovar qo'shildi",
  'product_updated': "Tovar o'zgartirildi",
  'price_changed': "Narx o'zgardi",
  'product_deleted': "Tovar o'chirildi",
  'category_saved': 'Kategoriya saqlandi',
  'category_deleted': "Kategoriya o'chirildi",
  'user_created': "Xodim qo'shildi",
  'user_updated': "Xodim o'zgartirildi",
  'user_deleted': "Xodim o'chirildi",
  'branch_saved': 'Filial saqlandi',
  'branch_deleted': "Filial o'chirildi",
  'supplier_purchase': 'Firmadan kirim',
  'supplier_payment': "Firmaga to'lov",
  'customer_saved': "Mijoz qo'shildi",
  'customer_payment': "Mijoz qarzini to'ladi",
  'customer_debt': 'Mijozga qarz yozildi',
};

ActivityKind activityKindOf(String action) {
  if (action.startsWith('product_') || action.startsWith('category_') || action == 'price_changed') {
    return ActivityKind.product;
  }
  if (action == 'refund' || action == 'discount_approved') return ActivityKind.sale;
  if (action.startsWith('supplier_')) return ActivityKind.supplier;
  if (action.startsWith('customer_')) return ActivityKind.sale;
  if (action.startsWith('user_') || action.startsWith('branch_') || action == 'login') return ActivityKind.staff;
  return ActivityKind.other;
}

class ActivityEntry {
  const ActivityEntry({
    required this.at,
    required this.kind,
    required this.title,
    required this.details,
    required this.userName,
    this.action = '',
    this.branchId = '',
  });

  final int at;
  final ActivityKind kind;
  final String action;
  final String title;
  final String details;
  final String userName;
  final String branchId;
}

/// Bir kunlik (davr) o'zgarishlar: yig'indi raqamlar va to'liq ro'yxat.
class ActivityDay {
  const ActivityDay({
    this.productsAdded = 0,
    this.productsEdited = 0,
    this.priceChanges = 0,
    this.productsDeleted = 0,
    this.receiptCount = 0,
    this.receiptQty = 0,
    this.writeOffCount = 0,
    this.writeOffQty = 0,
    this.adjustmentCount = 0,
    this.saleCount = 0,
    this.saleTotal = 0,
    this.refundCount = 0,
    this.entries = const [],
  });

  final int productsAdded;
  final int productsEdited;
  final int priceChanges;
  final int productsDeleted;
  final int receiptCount;
  final double receiptQty;

  /// Hisobdan chiqarish va firmaga qaytarish.
  final int writeOffCount;
  final double writeOffQty;
  final int adjustmentCount;
  final int saleCount;
  final int saleTotal;
  final int refundCount;
  final List<ActivityEntry> entries;
}

/// "Dasturdagi har qanday o'zgarish" jurnali: audit yozuvlari (tovar, xodim,
/// firma...) va ombor harakatlari bitta ro'yxatda, joriy filial bo'yicha.
class ActivityRepository {
  ActivityRepository(this.db, this.deviceId, {BranchContext? branch, this.currentUser})
    : branch = branch ?? BranchContext();

  final AppDatabase db;
  final Future<String> Function() deviceId;
  final BranchContext branch;

  /// Amalni bajarayotgan xodim (tizimga kirgan foydalanuvchi).
  final User? Function()? currentUser;

  /// Jurnalga yozish. `global` — tovar, kategoriya, xodim kabi barcha
  /// filiallarga tegishli o'zgarish (hamma filial jurnalida ko'rinadi).
  Future<void> log(String action, {String details = '', String refId = '', bool global = false, User? user}) async {
    final u = user ?? currentUser?.call();
    final now = Ids.nowMs();
    await db.into(db.auditLog).insert(AuditLogCompanion.insert(
          id: Ids.newId(),
          userId: u?.id ?? '',
          userName: u?.fullName ?? '',
          action: action,
          details: Value(details),
          refId: Value(refId),
          branchId: Value(global ? '' : branch.id),
          createdAt: now,
          updatedAt: now,
          deviceId: Value(await deviceId()),
        ));
  }

  Stream<ActivityDay> watchDay(DayRange r) => watchInBranch(branch, (b) async* {
    yield await load(r, b);
    await for (final _ in db.tableUpdates(
      TableUpdateQuery.onAllTables([db.auditLog, db.stockMovements, db.products, db.sales]),
    )) {
      yield await load(r, b);
    }
  });

  Future<ActivityDay> load(DayRange r, String branchId) async {
    final from = Variable.withInt(r.fromMs), to = Variable.withInt(r.toMs), b = Variable.withString(branchId);

    final audit = await db.customSelect(
      "SELECT * FROM audit_log WHERE created_at >= ? AND created_at < ? AND (branch_id = ? OR branch_id = '') "
      'ORDER BY created_at DESC LIMIT 1000',
      variables: [from, to, b],
    ).get();
    final moves = await db.customSelect(
      'SELECT m.*, COALESCE(p.name, m.product_id) pname, COALESCE(p.unit, \'\') punit FROM stock_movements m '
      'LEFT JOIN products p ON p.id = m.product_id '
      "WHERE m.created_at >= ? AND m.created_at < ? AND m.branch_id = ? AND m.is_deleted = 0 "
      "AND m.type NOT IN ('sale', 'customer_return') ORDER BY m.created_at DESC LIMIT 1000",
      variables: [from, to, b],
    ).get();
    final products = await db.customSelect(
      'SELECT SUM(CASE WHEN created_at >= ?1 AND created_at < ?2 AND is_deleted = 0 THEN 1 ELSE 0 END) added, '
      'SUM(CASE WHEN is_deleted = 1 AND updated_at >= ?1 AND updated_at < ?2 THEN 1 ELSE 0 END) deleted '
      'FROM products',
      variables: [from, to],
    ).getSingle();
    final sales = await db.customSelect(
      "SELECT SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) c, "
      "COALESCE(SUM(CASE WHEN status = 'completed' THEN total ELSE 0 END), 0) t, "
      "SUM(CASE WHEN status = 'refunded' THEN 1 ELSE 0 END) r "
      'FROM sales WHERE created_at >= ? AND created_at < ? AND branch_id = ? AND is_deleted = 0',
      variables: [from, to, b],
    ).getSingle();

    final entries = <ActivityEntry>[];
    var edited = 0, prices = 0;
    for (final row in audit) {
      final a = db.auditLog.map(row.data);
      if (a.action == 'product_updated') edited++;
      if (a.action == 'price_changed') prices++;
      entries.add(ActivityEntry(
        at: a.createdAt,
        kind: activityKindOf(a.action),
        action: a.action,
        title: kActivityLabels[a.action] ?? a.action,
        details: a.details,
        userName: a.userName,
        branchId: a.branchId,
      ));
    }
    var receipts = 0, writeOffs = 0, adjustments = 0;
    var receiptQty = 0.0, writeOffQty = 0.0;
    for (final row in moves) {
      final m = db.stockMovements.map(row.data);
      final type = MovementType.fromCode(m.type);
      switch (type) {
        case MovementType.receipt:
          receipts++;
          receiptQty += m.qty;
        case MovementType.writeOff || MovementType.supplierReturn:
          writeOffs++;
          writeOffQty -= m.qty;
        case MovementType.adjustment:
          adjustments++;
        default:
          break;
      }
      final sign = m.qty > 0 ? '+' : '';
      entries.add(ActivityEntry(
        at: m.createdAt,
        kind: ActivityKind.stock,
        action: 'stock_${m.type}',
        title: 'Ombor: ${type.label}',
        details: '${row.read<String>('pname')}: $sign${Fmt.qty(m.qty)} ${row.read<String>('punit')}'
            '${m.note.isEmpty ? '' : ' — ${m.note}'}',
        userName: m.userName,
        branchId: m.branchId,
      ));
    }
    entries.sort((x, y) => y.at.compareTo(x.at));

    return ActivityDay(
      productsAdded: products.read<int?>('added') ?? 0,
      productsDeleted: products.read<int?>('deleted') ?? 0,
      productsEdited: edited,
      priceChanges: prices,
      receiptCount: receipts,
      receiptQty: receiptQty,
      writeOffCount: writeOffs,
      writeOffQty: writeOffQty,
      adjustmentCount: adjustments,
      saleCount: sales.read<int?>('c') ?? 0,
      saleTotal: sales.read<int>('t'),
      refundCount: sales.read<int?>('r') ?? 0,
      entries: entries,
    );
  }

  /// Oxirgi o'zgarishlar (monitoring uchun, berilgan filiallar bo'yicha).
  Stream<List<ActivityEntry>> watchRecent(List<String> branchIds, {int limit = 15}) async* {
    Future<List<ActivityEntry>> load() async {
      final today = DayRange.today();
      final all = <ActivityEntry>[];
      for (final b in branchIds) {
        all.addAll((await this.load(today, b)).entries.where((e) => e.branchId == b || branchIds.first == b));
      }
      all.sort((x, y) => y.at.compareTo(x.at));
      return all.take(limit).toList();
    }

    yield await load();
    await for (final _ in db.tableUpdates(TableUpdateQuery.onAllTables([db.auditLog, db.stockMovements]))) {
      yield await load();
    }
  }
}
