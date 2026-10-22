import 'package:drift/drift.dart';

import '../../core/branch.dart';
import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

/// Savdo tarixi filtrlari.
class SaleFilter {
  const SaleFilter({
    this.fromMs,
    this.toMs,
    this.cashierId,
    this.paymentType,
    this.minTotal,
    this.maxTotal,
    this.status,
    this.receiptQuery = '',
    this.limit = 500,
  });

  final int? fromMs;
  final int? toMs;
  final String? cashierId;
  final PaymentType? paymentType;
  final int? minTotal;
  final int? maxTotal;
  final SaleStatus? status;
  final String receiptQuery;
  final int limit;

  SaleFilter copyWith({
    int? Function()? fromMs,
    int? Function()? toMs,
    String? Function()? cashierId,
    PaymentType? Function()? paymentType,
    int? Function()? minTotal,
    int? Function()? maxTotal,
    SaleStatus? Function()? status,
    String? receiptQuery,
  }) =>
      SaleFilter(
        fromMs: fromMs != null ? fromMs() : this.fromMs,
        toMs: toMs != null ? toMs() : this.toMs,
        cashierId: cashierId != null ? cashierId() : this.cashierId,
        paymentType: paymentType != null ? paymentType() : this.paymentType,
        minTotal: minTotal != null ? minTotal() : this.minTotal,
        maxTotal: maxTotal != null ? maxTotal() : this.maxTotal,
        status: status != null ? status() : this.status,
        receiptQuery: receiptQuery ?? this.receiptQuery,
        limit: limit,
      );

  @override
  bool operator ==(Object other) =>
      other is SaleFilter &&
      other.fromMs == fromMs &&
      other.toMs == toMs &&
      other.cashierId == cashierId &&
      other.paymentType == paymentType &&
      other.minTotal == minTotal &&
      other.maxTotal == maxTotal &&
      other.status == status &&
      other.receiptQuery == receiptQuery &&
      other.limit == limit;

  @override
  int get hashCode =>
      Object.hash(fromMs, toMs, cashierId, paymentType, minTotal, maxTotal, status, receiptQuery, limit);
}

/// Chek va uning qatorlari.
class SaleWithItems {
  SaleWithItems(this.sale, this.items);
  final Sale sale;
  final List<SaleItem> items;
}

class SaleRepository {
  SaleRepository(this.db, {BranchContext? branch}) : branch = branch ?? BranchContext();
  final AppDatabase db;
  final BranchContext branch;

  Stream<List<Sale>> watchSales(SaleFilter f) => watchInBranch(branch, (b) => _watchSales(f, b));

  Stream<List<Sale>> _watchSales(SaleFilter f, String branchId) {
    final q = db.select(db.sales)..where((s) => s.isDeleted.equals(false) & s.branchId.equals(branchId));
    if (f.fromMs != null) q.where((s) => s.createdAt.isBiggerOrEqualValue(f.fromMs!));
    if (f.toMs != null) q.where((s) => s.createdAt.isSmallerThanValue(f.toMs!));
    if (f.cashierId != null) q.where((s) => s.cashierId.equals(f.cashierId!));
    if (f.paymentType != null) q.where((s) => s.paymentType.equals(f.paymentType!.code));
    if (f.minTotal != null) q.where((s) => s.total.isBiggerOrEqualValue(f.minTotal!));
    if (f.maxTotal != null) q.where((s) => s.total.isSmallerOrEqualValue(f.maxTotal!));
    if (f.status != null) q.where((s) => s.status.equals(f.status!.code));
    if (f.receiptQuery.trim().isNotEmpty) {
      q.where((s) => s.receiptNo.like('%${f.receiptQuery.trim()}%'));
    }
    q
      ..orderBy([(s) => OrderingTerm.desc(s.createdAt)])
      ..limit(f.limit);
    return q.watch();
  }

  Future<SaleWithItems?> getWithItems(String saleId) async {
    final sale = await (db.select(db.sales)..where((s) => s.id.equals(saleId))).getSingleOrNull();
    if (sale == null) return null;
    final items = await (db.select(db.saleItems)
          ..where((i) => i.saleId.equals(saleId))
          ..orderBy([(i) => OrderingTerm(expression: i.createdAt)]))
        .get();
    return SaleWithItems(sale, items);
  }

  Stream<Sale?> watchLast() => watchInBranch(
      branch,
      (b) => (db.select(db.sales)
            ..where((s) => s.branchId.equals(b))
            ..orderBy([(s) => OrderingTerm.desc(s.createdAt)])
            ..limit(1))
          .watchSingleOrNull());

  /// Chekni "qaytarilgan" deb belgilash (ombor harakatlari servisda qo'shiladi).
  Future<void> markRefunded(Sale sale, User by) async {
    await (db.update(db.sales)..where((s) => s.id.equals(sale.id))).write(SalesCompanion(
      status: Value(SaleStatus.refunded.code),
      refundedAt: Value(Ids.nowMs()),
      refundedBy: Value(by.fullName),
      updatedAt: Value(Ids.nowMs()),
      version: Value(sale.version + 1),
      dirty: const Value(true),
    ));
  }

  /// Oxirgi 30 kundagi o'rtacha chek (anomaliya aniqlash uchun).
  Future<double> averageCheck({int days = 30}) async {
    final from = Ids.nowMs() - days * 86400000;
    final row = await db.customSelect(
      "SELECT AVG(total) AS a, COUNT(*) AS c FROM sales WHERE status = 'completed' "
      'AND is_deleted = 0 AND created_at >= ? AND branch_id = ?',
      variables: [Variable.withInt(from), Variable.withString(branch.id)],
    ).getSingle();
    final count = row.read<int>('c');
    if (count < 10) return 0; // Statistika yetarli emas
    return row.read<double?>('a') ?? 0;
  }
}
