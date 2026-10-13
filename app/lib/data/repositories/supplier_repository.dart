import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

/// Firma va uning hisob-kitob holati (qarzlar ro'yxati uchun).
class SupplierBalance {
  const SupplierBalance({
    required this.supplier,
    required this.purchased,
    required this.paid,
    this.lastPurchaseAt,
    this.purchaseCount = 0,
  });

  final Supplier supplier;

  /// Barcha kirimlar (va boshlang'ich qarz) summasi.
  final int purchased;

  /// Barcha to'lovlar summasi.
  final int paid;
  final int? lastPurchaseAt;
  final int purchaseCount;

  /// Musbat — biz firmaga qarzmiz; manfiy — firma bizga qarz (ortiqcha to'lov,
  /// kam kelgan yoki qaytarilgan tovar).
  int get debt => purchased - paid;
}

/// Qarzlar oynasining umumiy ko'rsatkichlari.
class DebtSummary {
  const DebtSummary({this.totalDebt = 0, this.debtorCount = 0, this.totalAdvance = 0, this.paidToday = 0});
  final int totalDebt;
  final int debtorCount;
  final int totalAdvance;
  final int paidToday;
}

/// Kirim hujjati va undan qolgan qarz (FIFO bo'yicha taqsimlangan).
class PurchaseWithStatus {
  const PurchaseWithStatus(this.purchase, this.covered);
  final SupplierPurchase purchase;

  /// Shu kirimga to'g'ri kelgan to'lov (eng eski kirim birinchi yopiladi).
  final int covered;
  int get remaining => purchase.total - covered;
  bool get isPaid => remaining <= 0;

  /// Kam kelgan / qaytarilgan tovar hujjati (qarzni kamaytiradi).
  bool get isCredit => purchase.total < 0;
}

/// Akt-sverka qatori: kirim yoki to'lov, keyingi qoldiq bilan.
class LedgerEntry {
  const LedgerEntry({
    required this.at,
    required this.title,
    required this.debit,
    required this.credit,
    required this.balance,
    this.purchase,
    this.payment,
  });
  final int at;
  final String title;

  /// Qarzni oshiradi (kirim).
  final int debit;

  /// Qarzni kamaytiradi (to'lov).
  final int credit;
  final int balance;
  final SupplierPurchase? purchase;
  final SupplierPayment? payment;
}

/// Kirim qatori kiritish uchun.
class PurchaseLineInput {
  const PurchaseLineInput({
    required this.productId,
    required this.productName,
    required this.qty,
    required this.price,
    this.barcode = '',
    this.unit = 'dona',
  });
  final String productId;
  final String productName;
  final String barcode;
  final String unit;
  final double qty;
  final int price;
  int get lineTotal => (qty * price).round();
}

/// Firmalar, kirim hujjatlari va qarzlar.
class SupplierRepository {
  SupplierRepository(this.db, this.deviceId);
  final AppDatabase db;
  final Future<String> Function() deviceId;

  // --------------------------------------------------------------------------
  //  Firmalar
  // --------------------------------------------------------------------------

  Stream<List<Supplier>> watchSuppliers() {
    final q = db.select(db.suppliers)
      ..where((s) => s.isDeleted.equals(false))
      ..orderBy([(s) => OrderingTerm.asc(s.name.collate(Collate.noCase))]);
    return q.watch();
  }

  Future<List<Supplier>> allSuppliers() {
    final q = db.select(db.suppliers)
      ..where((s) => s.isDeleted.equals(false))
      ..orderBy([(s) => OrderingTerm.asc(s.name.collate(Collate.noCase))]);
    return q.get();
  }

  Future<Supplier?> byId(String id) => (db.select(db.suppliers)..where((s) => s.id.equals(id))).getSingleOrNull();

  Stream<Supplier?> watchSupplier(String id) =>
      (db.select(db.suppliers)..where((s) => s.id.equals(id))).watchSingleOrNull();

  /// Yangi firma yaratish yoki tahrirlash. Qaytaradi: firma ID si.
  Future<String> saveSupplier({
    String? id,
    required String name,
    String phone = '',
    String contactPerson = '',
    String address = '',
    String note = '',
  }) async {
    final n = name.trim();
    if (n.isEmpty) throw Exception('Firma nomini kiriting');
    final dup = await (db.select(
      db.suppliers,
    )..where((s) => s.isDeleted.equals(false) & s.name.lower().equals(n.toLowerCase()))).getSingleOrNull();
    if (dup != null && dup.id != id) throw Exception('"$n" nomli firma allaqachon bor');
    final now = Ids.nowMs();
    final dev = await deviceId();
    if (id == null) {
      final newId = Ids.newId();
      await db
          .into(db.suppliers)
          .insert(
            SuppliersCompanion.insert(
              id: newId,
              name: n,
              phone: Value(phone.trim()),
              contactPerson: Value(contactPerson.trim()),
              address: Value(address.trim()),
              note: Value(note.trim()),
              createdAt: now,
              updatedAt: now,
              deviceId: Value(dev),
            ),
          );
      return newId;
    }
    final old = await byId(id);
    await (db.update(db.suppliers)..where((s) => s.id.equals(id))).write(
      SuppliersCompanion(
        name: Value(n),
        phone: Value(phone.trim()),
        contactPerson: Value(contactPerson.trim()),
        address: Value(address.trim()),
        note: Value(note.trim()),
        updatedAt: Value(now),
        version: Value((old?.version ?? 0) + 1),
        deviceId: Value(dev),
        dirty: const Value(true),
      ),
    );
    // Nom o'zgarsa — hujjatlardagi nusxani ham yangilaymiz (qidiruv va ro'yxat uchun).
    if (old != null && old.name != n) {
      await db.customUpdate(
        'UPDATE supplier_purchases SET supplier_name = ?, updated_at = ?, dirty = 1 WHERE supplier_id = ?',
        variables: [Variable.withString(n), Variable.withInt(now), Variable.withString(id)],
        updates: {db.supplierPurchases},
      );
    }
    return id;
  }

  /// Firmani o'chirish (yumshoq). Qarzi bo'lsa — ruxsat berilmaydi.
  Future<void> deleteSupplier(String id) async {
    final b = await balanceOf(id);
    if (b != 0) throw Exception("Firma bilan hisob yopilmagan (qoldiq ${b > 0 ? 'qarz' : 'avans'} bor)");
    await (db.update(db.suppliers)..where((s) => s.id.equals(id))).write(
      SuppliersCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(Ids.nowMs()),
        deviceId: Value(await deviceId()),
        dirty: const Value(true),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  Balanslar
  // --------------------------------------------------------------------------

  static const _balanceSql = '''
SELECT s.*,
  COALESCE((SELECT SUM(p.total) FROM supplier_purchases p WHERE p.supplier_id = s.id AND p.is_deleted = 0), 0) AS purchased,
  COALESCE((SELECT SUM(m.amount) FROM supplier_payments m WHERE m.supplier_id = s.id AND m.is_deleted = 0), 0) AS paid,
  (SELECT MAX(p.doc_date) FROM supplier_purchases p WHERE p.supplier_id = s.id AND p.is_deleted = 0) AS last_at,
  (SELECT COUNT(*) FROM supplier_purchases p WHERE p.supplier_id = s.id AND p.is_deleted = 0 AND p.kind = 'purchase') AS cnt
FROM suppliers s WHERE s.is_deleted = 0''';

  /// Barcha firmalar balansi bilan: avval eng ko'p qarz.
  Stream<List<SupplierBalance>> watchBalances() {
    return db
        .customSelect(_balanceSql, readsFrom: {db.suppliers, db.supplierPurchases, db.supplierPayments})
        .watch()
        .map((rows) {
          final list = rows
              .map(
                (r) => SupplierBalance(
                  supplier: db.suppliers.map(r.data),
                  purchased: r.read<int>('purchased'),
                  paid: r.read<int>('paid'),
                  lastPurchaseAt: r.readNullable<int>('last_at'),
                  purchaseCount: r.read<int>('cnt'),
                ),
              )
              .toList();
          list.sort((a, b) {
            final c = b.debt.compareTo(a.debt);
            return c != 0 ? c : a.supplier.name.toLowerCase().compareTo(b.supplier.name.toLowerCase());
          });
          return list;
        });
  }

  Stream<DebtSummary> watchSummary() {
    final start = DateTime.now();
    final today = DateTime(start.year, start.month, start.day).millisecondsSinceEpoch;
    return watchBalances().asyncMap((list) async {
      final paidToday = await db
          .customSelect(
            'SELECT COALESCE(SUM(amount), 0) AS s FROM supplier_payments '
            'WHERE is_deleted = 0 AND amount > 0 AND paid_at >= ?',
            variables: [Variable.withInt(today)],
          )
          .getSingle();
      var debt = 0, advance = 0, n = 0;
      for (final b in list) {
        if (b.debt > 0) {
          debt += b.debt;
          n++;
        } else {
          advance -= b.debt;
        }
      }
      return DebtSummary(totalDebt: debt, debtorCount: n, totalAdvance: advance, paidToday: paidToday.read<int>('s'));
    });
  }

  /// Bitta firmaning joriy qoldig'i (musbat — qarz).
  Future<int> balanceOf(String supplierId) async {
    final r = await db
        .customSelect(
          'SELECT '
          '(SELECT COALESCE(SUM(total), 0) FROM supplier_purchases WHERE supplier_id = ? AND is_deleted = 0) - '
          '(SELECT COALESCE(SUM(amount), 0) FROM supplier_payments WHERE supplier_id = ? AND is_deleted = 0) AS b',
          variables: [Variable.withString(supplierId), Variable.withString(supplierId)],
        )
        .getSingle();
    return r.read<int>('b');
  }

  // --------------------------------------------------------------------------
  //  Kirimlar va to'lovlar
  // --------------------------------------------------------------------------

  Stream<List<SupplierPurchase>> watchPurchases(String supplierId) {
    final q = db.select(db.supplierPurchases)
      ..where((p) => p.supplierId.equals(supplierId) & p.isDeleted.equals(false))
      ..orderBy([(p) => OrderingTerm.desc(p.docDate)]);
    return q.watch();
  }

  Stream<List<SupplierPayment>> watchPayments(String supplierId) {
    final q = db.select(db.supplierPayments)
      ..where((p) => p.supplierId.equals(supplierId) & p.isDeleted.equals(false))
      ..orderBy([(p) => OrderingTerm.desc(p.paidAt)]);
    return q.watch();
  }

  Stream<SupplierPurchase?> watchPurchase(String id) =>
      (db.select(db.supplierPurchases)..where((p) => p.id.equals(id))).watchSingleOrNull();

  Stream<List<SupplierPurchaseItem>> watchItems(String purchaseId) {
    final q = db.select(db.supplierPurchaseItems)
      ..where((i) => i.purchaseId.equals(purchaseId) & i.isDeleted.equals(false))
      ..orderBy([(i) => OrderingTerm.asc(i.productName.collate(Collate.noCase))]);
    return q.watch();
  }

  /// Kirim hujjatlari to'lov holati bilan. To'lovlar eng eski kirimdan
  /// boshlab yopadi (FIFO) — qaysi nakladnoy hali to'lanmaganini ko'rsatadi.
  static List<PurchaseWithStatus> allocate(List<SupplierPurchase> purchases, int totalPaid) {
    final asc = [...purchases]
      ..sort((a, b) => a.docDate != b.docDate ? a.docDate.compareTo(b.docDate) : a.createdAt.compareTo(b.createdAt));
    // Kam kelgan / qaytarilgan tovar hujjatlari to'lov kabi qarzni yopadi.
    var pool = totalPaid + asc.where((p) => p.total < 0).fold<int>(0, (s, p) => s - p.total);
    final covered = <String, int>{};
    for (final p in asc) {
      if (p.total < 0) {
        covered[p.id] = p.total;
        continue;
      }
      final c = pool <= 0 ? 0 : (pool >= p.total ? p.total : pool);
      covered[p.id] = c;
      pool -= c;
    }
    return [for (final p in purchases) PurchaseWithStatus(p, covered[p.id] ?? 0)];
  }

  /// Akt-sverka: kirim va to'lovlar vaqt tartibida, har qadamda qoldiq.
  /// Natija — eng yangisi birinchi.
  static List<LedgerEntry> ledger(List<SupplierPurchase> purchases, List<SupplierPayment> payments) {
    final events = <(int, int, Object)>[
      for (final p in purchases) (p.docDate, p.createdAt, p),
      for (final m in payments) (m.paidAt, m.createdAt, m),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    var balance = 0;
    final out = <LedgerEntry>[];
    for (final e in events) {
      final o = e.$3;
      if (o is SupplierPurchase) {
        balance += o.total;
        final kind = PurchaseKind.fromCode(o.kind);
        out.add(
          LedgerEntry(
            at: o.docDate,
            title: switch (kind) {
              PurchaseKind.purchase => 'Kirim${o.docNo.isEmpty ? '' : ' №${o.docNo}'}',
              PurchaseKind.credit => o.note.isEmpty ? kind.label : '${kind.label}: ${o.note}',
              PurchaseKind.opening => kind.label,
            },
            debit: o.total > 0 ? o.total : 0,
            credit: o.total < 0 ? -o.total : 0,
            balance: balance,
            purchase: o,
          ),
        );
      } else if (o is SupplierPayment) {
        balance -= o.amount;
        final method = PaymentType.fromCode(o.method).label;
        out.add(
          LedgerEntry(
            at: o.paidAt,
            title: o.amount < 0 ? 'Firma pulni qaytardi ($method)' : "To'lov ($method)",
            debit: o.amount < 0 ? -o.amount : 0,
            credit: o.amount > 0 ? o.amount : 0,
            balance: balance,
            payment: o,
          ),
        );
      }
    }
    return out.reversed.toList();
  }

  /// Firmadan kirim hujjatini yozish (+ darhol to'langan summa).
  /// Ombor harakatlari alohida (StockRepository) yoziladi — `refId` sifatida
  /// shu funksiya qaytargan ID ishlatiladi.
  Future<String> createPurchase({
    required String supplierId,
    required List<PurchaseLineInput> lines,
    required String userId,
    required String userName,
    PurchaseKind kind = PurchaseKind.purchase,
    int? total,
    String docNo = '',
    int? docDate,
    List<String> imagePaths = const [],
    String note = '',
    int paidNow = 0,
    PaymentType method = PaymentType.cash,
    String receivedBy = '',
    String signaturePath = '',
    String? id,
  }) async {
    final supplier = await byId(supplierId);
    if (supplier == null) throw Exception('Firma topilmadi');
    final sum = total ?? lines.fold<int>(0, (s, l) => s + l.lineTotal);
    if (kind == PurchaseKind.credit ? sum > 0 : sum < 0) throw Exception("Summa ishorasi noto'g'ri");
    if (paidNow < 0) throw Exception("To'lov manfiy bo'lishi mumkin emas");
    final now = Ids.nowMs();
    final dev = await deviceId();
    final pid = id ?? Ids.newId();
    final date = docDate ?? now;
    await db.transaction(() async {
      await db
          .into(db.supplierPurchases)
          .insert(
            SupplierPurchasesCompanion.insert(
              id: pid,
              supplierId: supplierId,
              supplierName: Value(supplier.name),
              kind: Value(kind.code),
              docNo: Value(docNo.trim()),
              docDate: date,
              total: Value(sum),
              itemCount: Value(lines.fold<double>(0, (s, l) => s + l.qty)),
              imagePaths: Value(imagePaths.join(',')),
              note: Value(note.trim()),
              userId: Value(userId),
              userName: Value(userName),
              createdAt: now,
              updatedAt: now,
              deviceId: Value(dev),
            ),
          );
      for (final l in lines) {
        await db
            .into(db.supplierPurchaseItems)
            .insert(
              SupplierPurchaseItemsCompanion.insert(
                id: Ids.newId(),
                purchaseId: pid,
                productId: l.productId,
                productName: l.productName,
                barcode: Value(l.barcode),
                unit: Value(l.unit),
                qty: l.qty,
                price: l.price,
                lineTotal: l.lineTotal,
                createdAt: now,
                updatedAt: now,
                deviceId: Value(dev),
              ),
            );
      }
      if (paidNow > 0) {
        await _insertPayment(
          supplierId: supplierId,
          purchaseId: pid,
          amount: paidNow,
          method: method,
          paidAt: date,
          note: kind == PurchaseKind.purchase ? 'Kirim paytida' : '',
          receivedBy: receivedBy,
          signaturePath: signaturePath,
          userId: userId,
          userName: userName,
          now: now,
          dev: dev,
        );
      }
    });
    return pid;
  }

  /// Qarzni (to'liq yoki qisman) to'lash. [refund] — aksincha, firma bizga
  /// pul qaytardi (firma qarzi kamayadi): summa manfiy saqlanadi.
  Future<String> addPayment({
    required String supplierId,
    required int amount,
    required String userId,
    required String userName,
    PaymentType method = PaymentType.cash,
    String? purchaseId,
    int? paidAt,
    String note = '',
    String receivedBy = '',
    String signaturePath = '',
    bool refund = false,
  }) async {
    if (amount <= 0) throw Exception("To'lov summasini kiriting");
    return _insertPayment(
      supplierId: supplierId,
      purchaseId: purchaseId,
      amount: refund ? -amount : amount,
      receivedBy: receivedBy,
      signaturePath: signaturePath,
      method: method,
      paidAt: paidAt ?? Ids.nowMs(),
      note: note,
      userId: userId,
      userName: userName,
      now: Ids.nowMs(),
      dev: await deviceId(),
    );
  }

  Future<String> _insertPayment({
    required String supplierId,
    required String? purchaseId,
    required int amount,
    required PaymentType method,
    required int paidAt,
    required String note,
    required String userId,
    required String userName,
    required int now,
    required String dev,
    String receivedBy = '',
    String signaturePath = '',
  }) async {
    final id = Ids.newId();
    await db
        .into(db.supplierPayments)
        .insert(
          SupplierPaymentsCompanion.insert(
            id: id,
            supplierId: supplierId,
            purchaseId: Value(purchaseId),
            amount: amount,
            method: Value(method.code),
            paidAt: paidAt,
            note: Value(note.trim()),
            userId: Value(userId),
            userName: Value(userName),
            receivedBy: Value(receivedBy.trim()),
            signaturePath: Value(signaturePath),
            createdAt: now,
            updatedAt: now,
            deviceId: Value(dev),
          ),
        );
    return id;
  }

  /// Kam kelgan / firmaga qaytarilgan tovar: qarzni [amount] ga kamaytiradi.
  /// [lines] berilsa — qaysi tovar qancha kam kelgani ham saqlanadi
  /// (ombordan ayirish chaqiruvchi tomonidan). Qaytaradi: hujjat ID si.
  Future<String> createCredit({
    required String supplierId,
    required String userId,
    required String userName,
    int? amount,
    List<PurchaseLineInput> lines = const [],
    String note = '',
    String docNo = '',
    List<String> imagePaths = const [],
  }) async {
    final sum = amount ?? lines.fold<int>(0, (s, l) => s + l.lineTotal);
    if (sum <= 0) throw Exception('Summani kiriting');
    return createPurchase(
      supplierId: supplierId,
      kind: PurchaseKind.credit,
      lines: lines,
      total: -sum,
      note: note,
      docNo: docNo,
      imagePaths: imagePaths,
      userId: userId,
      userName: userName,
    );
  }

  /// Xato kiritilgan to'lovni bekor qilish.
  Future<void> deletePayment(String id) async {
    await (db.update(db.supplierPayments)..where((p) => p.id.equals(id))).write(
      SupplierPaymentsCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(Ids.nowMs()),
        deviceId: Value(await deviceId()),
        dirty: const Value(true),
      ),
    );
  }

  /// Kirim hujjatini bekor qilish (yumshoq). Ombordagi tovarlar alohida
  /// qaytariladi (chaqiruvchi tomonidan). Qaytaradi: hujjat qatorlari.
  Future<List<SupplierPurchaseItem>> deletePurchase(String id) async {
    final items = await (db.select(db.supplierPurchaseItems)..where((i) => i.purchaseId.equals(id))).get();
    await (db.update(db.supplierPurchases)..where((p) => p.id.equals(id))).write(
      SupplierPurchasesCompanion(
        isDeleted: const Value(true),
        updatedAt: Value(Ids.nowMs()),
        deviceId: Value(await deviceId()),
        dirty: const Value(true),
      ),
    );
    return items;
  }

  /// Prays-list / nakladnoy suratlarini yangilash.
  Future<void> setPurchaseImages(String id, List<String> names) async {
    final old = await (db.select(db.supplierPurchases)..where((p) => p.id.equals(id))).getSingleOrNull();
    await (db.update(db.supplierPurchases)..where((p) => p.id.equals(id))).write(
      SupplierPurchasesCompanion(
        imagePaths: Value(names.join(',')),
        updatedAt: Value(Ids.nowMs()),
        version: Value((old?.version ?? 0) + 1),
        deviceId: Value(await deviceId()),
        dirty: const Value(true),
      ),
    );
  }
}

/// Vergul bilan saqlangan rasm nomlari ro'yxati.
List<String> splitImagePaths(String s) => s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
