import 'package:drift/drift.dart';

import '../../core/branch.dart';
import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/security.dart';
import '../database.dart';
import 'activity_repository.dart';

/// Mijoz va uning qarzi (joriy filialda).
class CustomerBalance {
  const CustomerBalance({required this.customer, required this.debt, this.lastAt, this.saleCount = 0});
  final Customer customer;

  /// Musbat — mijoz bizga qarz; manfiy — oldindan to'lagan (avans).
  final int debt;
  final int? lastAt;
  final int saleCount;
}

class CustomerDebtSummary {
  const CustomerDebtSummary({this.totalDebt = 0, this.debtorCount = 0, this.paidToday = 0, this.debtToday = 0});
  final int totalDebt;
  final int debtorCount;
  final int paidToday;
  final int debtToday;
}

/// Mijoz qarzi daftari qatori (keyingi qoldiq bilan).
class CustomerLedgerEntry {
  const CustomerLedgerEntry(this.entry, this.balance, {this.receiptNo = ''});
  final CustomerDebt entry;
  final int balance;
  final String receiptNo;
  CustomerDebtKind get kind => CustomerDebtKind.fromCode(entry.kind);
}

class CustomerException implements Exception {
  CustomerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Mijozlar (umumiy) va ularning nasiya qarzlari (har bir filialda alohida).
class CustomerRepository {
  CustomerRepository(this.db, this.deviceId, {BranchContext? branch, this.activity})
    : branch = branch ?? BranchContext();

  final AppDatabase db;
  final Future<String> Function() deviceId;
  final BranchContext branch;
  final ActivityRepository? activity;

  // --------------------------------------------------------------------------
  //  Mijozlar
  // --------------------------------------------------------------------------

  Stream<List<Customer>> watchCustomers() {
    final q = db.select(db.customers)
      ..where((c) => c.isDeleted.equals(false))
      ..orderBy([(c) => OrderingTerm.asc(c.name.collate(Collate.noCase))]);
    return q.watch();
  }

  Stream<Customer?> watchCustomer(String id) =>
      (db.select(db.customers)..where((c) => c.id.equals(id))).watchSingleOrNull();

  Future<Customer> save({String? id, required String name, String phone = '', String address = '', String note = ''}) async {
    final n = name.trim();
    if (n.isEmpty) throw CustomerException('Mijoz ismini kiriting');
    final now = Ids.nowMs();
    final dev = await deviceId();
    final cid = id ?? Ids.newId();
    if (id == null) {
      await db.into(db.customers).insert(CustomersCompanion.insert(
            id: cid,
            name: n,
            phone: Value(phone.trim()),
            address: Value(address.trim()),
            note: Value(note.trim()),
            createdAt: now,
            updatedAt: now,
            deviceId: Value(dev),
          ));
      await activity?.log('customer_saved', details: n, refId: cid, global: true);
    } else {
      await (db.update(db.customers)..where((c) => c.id.equals(id))).write(CustomersCompanion(
        name: Value(n),
        phone: Value(phone.trim()),
        address: Value(address.trim()),
        note: Value(note.trim()),
        updatedAt: Value(now),
        deviceId: Value(dev),
        dirty: const Value(true),
      ));
    }
    return (await (db.select(db.customers)..where((c) => c.id.equals(cid))).getSingle());
  }

  /// O'chirish (faqat qarzi bo'lmasa).
  Future<void> delete(String id) async {
    if (await debtOf(id) != 0) throw CustomerException("Qarzi yopilmagan mijozni o'chirib bo'lmaydi");
    await (db.update(db.customers)..where((c) => c.id.equals(id))).write(CustomersCompanion(
      isDeleted: const Value(true),
      updatedAt: Value(Ids.nowMs()),
      deviceId: Value(await deviceId()),
      dirty: const Value(true),
    ));
  }

  // --------------------------------------------------------------------------
  //  Qarz va to'lovlar
  // --------------------------------------------------------------------------

  Future<int> debtOf(String customerId, {String? branchId}) async {
    final r = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) d FROM customer_debts WHERE customer_id = ? AND branch_id = ? AND is_deleted = 0',
      variables: [Variable.withString(customerId), Variable.withString(branchId ?? branch.id)],
    ).getSingle();
    return r.read<int>('d');
  }

  Stream<int> watchDebt(String customerId) => watchInBranch(
        branch,
        (b) => db.customSelect(
          'SELECT COALESCE(SUM(amount), 0) d FROM customer_debts WHERE customer_id = ? AND branch_id = ? AND is_deleted = 0',
          variables: [Variable.withString(customerId), Variable.withString(b)],
          readsFrom: {db.customerDebts},
        ).watchSingle().map((r) => r.read<int>('d')),
      );

  /// Daftarga yozuv qo'shish (savdo tranzaksiyasi ichidan ham chaqiriladi).
  Future<CustomerDebt> addEntry({
    required String customerId,
    required CustomerDebtKind kind,
    required int amount,
    String saleId = '',
    String method = '',
    String note = '',
    User? user,
    String? branchId,
  }) async {
    final now = Ids.nowMs();
    final e = CustomerDebt(
      id: Ids.newId(),
      customerId: customerId,
      kind: kind.code,
      amount: amount,
      saleId: saleId,
      method: method,
      note: note.trim(),
      userId: user?.id ?? '',
      userName: user?.fullName ?? '',
      branchId: branchId ?? branch.id,
      createdAt: now,
      updatedAt: now,
      version: 1,
      deviceId: await deviceId(),
      isDeleted: false,
      dirty: true,
    );
    await db.into(db.customerDebts).insert(e);
    return e;
  }

  /// Mijozdan qarz to'lovini qabul qilish.
  Future<void> addPayment(String customerId, int amount, {String method = 'cash', String note = '', User? user}) async {
    if (amount <= 0) throw CustomerException("To'lov summasi 0 dan katta bo'lishi kerak");
    await addEntry(
        customerId: customerId, kind: CustomerDebtKind.payment, amount: -amount, method: method, note: note, user: user);
    await activity?.log('customer_payment', details: '${await _name(customerId)}: ${Fmt.money(amount)}', refId: customerId, user: user);
  }

  /// Qo'lda qarz yozish (masalan, daftardagi eski qarzni kiritish).
  Future<void> addManualDebt(String customerId, int amount, {String note = '', User? user}) async {
    if (amount <= 0) throw CustomerException("Qarz summasi 0 dan katta bo'lishi kerak");
    await addEntry(customerId: customerId, kind: CustomerDebtKind.manual, amount: amount, note: note, user: user);
    await activity?.log('customer_debt', details: '${await _name(customerId)}: ${Fmt.money(amount)}', refId: customerId, user: user);
  }

  /// Xato kiritilgan to'lov yoki qo'lda yozilgan qarzni bekor qilish.
  Future<void> deleteEntry(String id) async {
    final e = await (db.select(db.customerDebts)..where((d) => d.id.equals(id))).getSingleOrNull();
    if (e == null) return;
    if (e.kind == CustomerDebtKind.sale.code || e.kind == CustomerDebtKind.refund.code) {
      throw CustomerException("Nasiya savdoni chekni qaytarish orqali bekor qiling");
    }
    await (db.update(db.customerDebts)..where((d) => d.id.equals(id))).write(CustomerDebtsCompanion(
      isDeleted: const Value(true),
      updatedAt: Value(Ids.nowMs()),
      deviceId: Value(await deviceId()),
      dirty: const Value(true),
    ));
  }

  Future<String> _name(String id) async =>
      (await (db.select(db.customers)..where((c) => c.id.equals(id))).getSingleOrNull())?.name ?? '';

  /// Mijoz daftari: eng yangisi tepada, har qatordan keyingi qoldiq bilan.
  Stream<List<CustomerLedgerEntry>> watchLedger(String customerId) => watchInBranch(
        branch,
        (b) => db.customSelect(
          'SELECT d.*, COALESCE(s.receipt_no, \'\') receipt_no FROM customer_debts d '
          'LEFT JOIN sales s ON s.id = d.sale_id '
          'WHERE d.customer_id = ? AND d.branch_id = ? AND d.is_deleted = 0 ORDER BY d.created_at',
          variables: [Variable.withString(customerId), Variable.withString(b)],
          readsFrom: {db.customerDebts, db.sales},
        ).watch().map((rows) {
          var bal = 0;
          final out = <CustomerLedgerEntry>[];
          for (final r in rows) {
            final e = db.customerDebts.map(r.data);
            bal += e.amount;
            out.add(CustomerLedgerEntry(e, bal, receiptNo: r.read<String>('receipt_no')));
          }
          return out.reversed.toList();
        }),
      );

  Stream<List<CustomerBalance>> watchBalances() => watchInBranch(
        branch,
        (b) => db.customSelect(
          'SELECT c.*, COALESCE(x.debt, 0) debt, x.last_at, COALESCE(x.sales, 0) sales FROM customers c '
          'LEFT JOIN (SELECT customer_id, SUM(amount) debt, MAX(created_at) last_at, '
          "SUM(CASE WHEN kind = 'sale' THEN 1 ELSE 0 END) sales FROM customer_debts "
          'WHERE branch_id = ? AND is_deleted = 0 GROUP BY customer_id) x ON x.customer_id = c.id '
          'WHERE c.is_deleted = 0 ORDER BY debt DESC, c.name COLLATE NOCASE',
          variables: [Variable.withString(b)],
          readsFrom: {db.customers, db.customerDebts},
        ).watch().map((rows) => [
              for (final r in rows)
                CustomerBalance(
                  customer: db.customers.map(r.data),
                  debt: r.read<int>('debt'),
                  lastAt: r.read<int?>('last_at'),
                  saleCount: r.read<int>('sales'),
                ),
            ]),
      );

  Stream<CustomerDebtSummary> watchSummary() => watchInBranch(branch, (b) {
        final today = DayRange.today();
        return db.customSelect(
          'SELECT COALESCE(SUM(CASE WHEN debt > 0 THEN debt ELSE 0 END), 0) total, '
          'COALESCE(SUM(CASE WHEN debt > 0 THEN 1 ELSE 0 END), 0) debtors, '
          '(SELECT COALESCE(-SUM(amount), 0) FROM customer_debts WHERE branch_id = ?1 AND is_deleted = 0 '
          "AND kind = 'payment' AND created_at >= ?2 AND created_at < ?3) paid_today, "
          '(SELECT COALESCE(SUM(amount), 0) FROM customer_debts WHERE branch_id = ?1 AND is_deleted = 0 '
          "AND kind = 'sale' AND created_at >= ?2 AND created_at < ?3) debt_today "
          'FROM (SELECT customer_id, SUM(amount) debt FROM customer_debts WHERE branch_id = ?1 AND is_deleted = 0 '
          'GROUP BY customer_id)',
          variables: [Variable.withString(b), Variable.withInt(today.fromMs), Variable.withInt(today.toMs)],
          readsFrom: {db.customerDebts},
        ).watchSingle().map((r) => CustomerDebtSummary(
              totalDebt: r.read<int>('total'),
              debtorCount: r.read<int>('debtors'),
              paidToday: r.read<int>('paid_today'),
              debtToday: r.read<int>('debt_today'),
            ));
      });
}
