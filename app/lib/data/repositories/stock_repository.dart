import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

/// Ombor harakati kiritish uchun ma'lumot.
class MovementInput {
  const MovementInput({
    required this.productId,
    required this.type,
    required this.qty,
    this.unitCost = 0,
    this.note = '',
    this.refId,
  });

  final String productId;
  final MovementType type;

  /// Ishorali miqdor (+ kirim, - chiqim).
  final double qty;
  final int unitCost;
  final String note;
  final String? refId;
}

/// Ombor harakatlari jurnali bilan ishlash.
class StockRepository {
  StockRepository(this.db, this.deviceId);
  final AppDatabase db;
  final Future<String> Function() deviceId;

  /// Bir nechta harakatni bitta tranzaksiyada yozish va qoldiq keshini yangilash.
  /// Qaytaradi: o'zgargan tovar ID lari (alert tekshiruvi uchun).
  Future<Set<String>> addMovements(
    List<MovementInput> inputs, {
    required String userId,
    required String userName,
  }) async {
    if (inputs.isEmpty) return {};
    final dev = await deviceId();
    final now = Ids.nowMs();
    final touched = <String>{};
    await db.transaction(() async {
      for (final m in inputs) {
        await db.into(db.stockMovements).insert(StockMovementsCompanion.insert(
              id: Ids.newId(),
              productId: m.productId,
              type: m.type.code,
              qty: m.qty,
              unitCost: Value(m.unitCost),
              refId: Value(m.refId),
              note: Value(m.note),
              userId: Value(userId),
              userName: Value(userName),
              createdAt: now,
              updatedAt: now,
              deviceId: Value(dev),
            ));
        // Keshni inkremental yangilash (tez). To'liq qayta hisob — recompute().
        await db.customUpdate(
          'UPDATE products SET stock_qty = stock_qty + ? WHERE id = ?',
          variables: [Variable.withReal(m.qty), Variable.withString(m.productId)],
          updates: {db.products},
        );
        touched.add(m.productId);
      }
    });
    return touched;
  }

  /// Qoldiqni harakatlar jurnalidan to'liq qayta hisoblash
  /// (sinxronlashdan keyin yoki tekshiruv uchun).
  Future<void> recompute([Iterable<String>? productIds]) async {
    const base = 'UPDATE products SET stock_qty = COALESCE((SELECT SUM(m.qty) FROM stock_movements m '
        'WHERE m.product_id = products.id AND m.is_deleted = 0), 0)';
    if (productIds == null) {
      await db.customUpdate(base, updates: {db.products});
      return;
    }
    final ids = productIds.toList();
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final ph = List.filled(chunk.length, '?').join(',');
      await db.customUpdate('$base WHERE id IN ($ph)',
          variables: chunk.map(Variable.withString).toList(), updates: {db.products});
    }
  }

  /// Harakatlar tarixi (tovar va/yoki davr bo'yicha).
  Stream<List<StockMovement>> watchMovements({String? productId, int? fromMs, int? toMs, int limit = 300}) {
    final q = db.select(db.stockMovements)..where((m) => m.isDeleted.equals(false));
    if (productId != null) q.where((m) => m.productId.equals(productId));
    if (fromMs != null) q.where((m) => m.createdAt.isBiggerOrEqualValue(fromMs));
    if (toMs != null) q.where((m) => m.createdAt.isSmallerThanValue(toMs));
    q
      ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
      ..limit(limit);
    return q.watch();
  }

  /// Ombor qiymati (tannarx va sotuv narxida).
  Stream<({double totalQty, int costValue, int saleValue})> watchInventoryValue() {
    return db
        .customSelect(
          'SELECT COALESCE(SUM(CASE WHEN stock_qty > 0 THEN stock_qty ELSE 0 END),0) AS q, '
          'COALESCE(SUM(CASE WHEN stock_qty > 0 THEN stock_qty * purchase_price ELSE 0 END),0) AS c, '
          'COALESCE(SUM(CASE WHEN stock_qty > 0 THEN stock_qty * sale_price ELSE 0 END),0) AS s '
          'FROM products WHERE is_deleted = 0',
          readsFrom: {db.products},
        )
        .watchSingle()
        .map((r) => (
              totalQty: r.read<double>('q'),
              costValue: r.read<double>('c').round(),
              saleValue: r.read<double>('s').round(),
            ));
  }
}
