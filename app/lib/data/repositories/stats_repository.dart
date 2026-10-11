import 'package:drift/drift.dart';

import '../../core/formatters.dart';
import '../../core/season.dart';
import '../database.dart';

/// Davr bo'yicha umumiy ko'rsatkichlar.
class PeriodSummary {
  const PeriodSummary({
    this.total = 0,
    this.count = 0,
    this.profit = 0,
    this.discount = 0,
    this.cash = 0,
    this.card = 0,
    this.transfer = 0,
  });

  final int total;
  final int count;
  final int profit;
  final int discount;
  final int cash;
  final int card;
  final int transfer;

  double get average => count == 0 ? 0 : total / count;
}

/// Tovar bo'yicha sotuv ko'rsatkichi.
class ProductSales {
  ProductSales({
    required this.productId,
    required this.name,
    required this.qty,
    required this.revenue,
    required this.receipts,
    this.product,
    this.fromTagOnly = false,
  });

  final String productId;
  final String name;
  final double qty;
  final int revenue;
  final int receipts;

  /// Savatga qo'shish uchun to'liq tovar (o'chirilgan bo'lsa null).
  final Product? product;

  /// Mavsumiy tavsiyalarda: statistika yo'q, faqat mavsum belgisi bo'yicha.
  final bool fromTagOnly;
}

class CashierSales {
  CashierSales(this.cashierId, this.name, this.total, this.count);
  final String cashierId;
  final String name;
  final int total;
  final int count;
}

class DailyPoint {
  DailyPoint(this.day, this.total, this.count);
  final DateTime day;
  final int total;
  final int count;
}

class SeasonSummary {
  SeasonSummary(this.season, this.qty, this.revenue);
  final Season season;
  final double qty;
  final int revenue;
}

/// SQL ifodasi: created_at (ms) dan mavsum indeksi va mavsum yili.
const _monthExpr = "CAST(strftime('%m', s.created_at / 1000, 'unixepoch', 'localtime') AS INTEGER)";
const _yearExpr = "CAST(strftime('%Y', s.created_at / 1000, 'unixepoch', 'localtime') AS INTEGER)";
const _seasonExpr =
    'CASE WHEN $_monthExpr IN (12,1,2) THEN 0 WHEN $_monthExpr IN (3,4,5) THEN 1 '
    'WHEN $_monthExpr IN (6,7,8) THEN 2 ELSE 3 END';
const _seasonYearExpr = 'CASE WHEN $_monthExpr = 12 THEN $_yearExpr + 1 ELSE $_yearExpr END';

/// Dashboard, tavsiyalar va mavsumiy tahlil uchun agregat so'rovlar.
/// Barcha `watch*` metodlari real-time: yangi sotuv bo'lishi bilan yangilanadi.
class StatsRepository {
  StatsRepository(this.db);
  final AppDatabase db;

  static const _completed = "s.status = 'completed' AND s.is_deleted = 0";

  Stream<PeriodSummary> watchSummary(DayRange r) {
    return db
        .customSelect(
          'SELECT COALESCE(SUM(s.total),0) t, COUNT(*) c, COALESCE(SUM(s.total - s.cost_total),0) p, '
          'COALESCE(SUM(s.discount_amount),0) d, '
          'COALESCE(SUM(s.paid_cash - s.change_amount),0) cash, COALESCE(SUM(s.paid_card),0) card, '
          'COALESCE(SUM(s.paid_transfer),0) tr '
          'FROM sales s WHERE $_completed AND s.created_at >= ? AND s.created_at < ?',
          variables: [Variable.withInt(r.fromMs), Variable.withInt(r.toMs)],
          readsFrom: {db.sales},
        )
        .watchSingle()
        .map((row) => PeriodSummary(
              total: row.read<int>('t'),
              count: row.read<int>('c'),
              profit: row.read<int>('p'),
              discount: row.read<int>('d'),
              cash: row.read<int>('cash'),
              card: row.read<int>('card'),
              transfer: row.read<int>('tr'),
            ));
  }

  /// Top sotilgan tovarlar (davr bo'yicha).
  Stream<List<ProductSales>> watchTopProducts(DayRange r, {int limit = 10, bool byRevenue = false}) {
    final order = byRevenue ? 'rev DESC' : 'q DESC';
    return _productSales(
      'SELECT si.product_id pid, MAX(si.product_name) n, SUM(si.qty) q, SUM(si.line_total) rev, '
      'COUNT(DISTINCT si.sale_id) rc FROM sale_items si JOIN sales s ON s.id = si.sale_id '
      'WHERE $_completed AND s.created_at >= ? AND s.created_at < ? '
      'GROUP BY si.product_id ORDER BY $order LIMIT ?',
      [Variable.withInt(r.fromMs), Variable.withInt(r.toMs), Variable.withInt(limit)],
    );
  }

  /// "Tez-tez sotiladigan tovarlar" — oxirgi N kun ichida eng ko'p cheklarda
  /// uchragan faol tovarlar.
  Stream<List<ProductSales>> watchFrequent({int days = 7, int limit = 24}) {
    final from = DayRange.lastDays(days).fromMs;
    return _productSales(
      'SELECT si.product_id pid, MAX(si.product_name) n, SUM(si.qty) q, SUM(si.line_total) rev, '
      'COUNT(DISTINCT si.sale_id) rc FROM sale_items si JOIN sales s ON s.id = si.sale_id '
      'JOIN products p ON p.id = si.product_id '
      'WHERE $_completed AND s.created_at >= ? AND p.is_deleted = 0 AND p.is_active = 1 '
      'GROUP BY si.product_id ORDER BY rc DESC, q DESC LIMIT ?',
      [Variable.withInt(from), Variable.withInt(limit)],
    );
  }

  /// Mavsumiy tavsiyalar: shu mavsumdagi tarixiy sotuvlar (joriy yil 2x vaznda),
  /// yetishmasa — mavsum belgisi qo'yilgan tovarlar bilan to'ldiriladi.
  Stream<List<ProductSales>> watchSeasonal(Season season, {int limit = 24}) {
    final year = Season.seasonYear(DateTime.now());
    return db
        .customSelect(
          'SELECT ss.product_id pid, p.name n, SUM(ss.qty * CASE WHEN ss.year = ? THEN 2 ELSE 1 END) score, '
          'SUM(ss.qty) q, SUM(ss.revenue) rev, SUM(ss.sale_count) rc '
          'FROM seasonal_stats ss JOIN products p ON p.id = ss.product_id '
          'WHERE ss.season = ? AND p.is_deleted = 0 AND p.is_active = 1 '
          'GROUP BY ss.product_id ORDER BY score DESC LIMIT ?',
          variables: [Variable.withInt(year), Variable.withInt(season.index0), Variable.withInt(limit)],
          readsFrom: {db.seasonalStats, db.products},
        )
        .watch()
        .asyncMap((rows) async {
      final list = rows
          .map((r) => ProductSales(
                productId: r.read<String>('pid'),
                name: r.read<String>('n'),
                qty: r.read<double>('q'),
                revenue: r.read<int>('rev'),
                receipts: r.read<int>('rc'),
              ))
          .toList();
      final products = await _productsById(list.map((e) => e.productId));
      final result = [
        for (final e in list)
          if (products[e.productId] != null)
            ProductSales(
              productId: e.productId,
              name: e.name,
              qty: e.qty,
              revenue: e.revenue,
              receipts: e.receipts,
              product: products[e.productId],
            ),
      ];
      if (result.length < limit) {
        // Mavsum belgisi bo'yicha to'ldirish.
        final tagged = await (db.select(db.products)
              ..where((p) =>
                  p.isDeleted.equals(false) &
                  p.isActive.equals(true) &
                  p.seasonTags.like('%${season.code}%') &
                  p.id.isNotIn(result.map((e) => e.productId)))
              ..orderBy([(p) => OrderingTerm.desc(p.stockQty)])
              ..limit(limit - result.length))
            .get();
        result.addAll(tagged.map((p) => ProductSales(
              productId: p.id,
              name: p.name,
              qty: 0,
              revenue: 0,
              receipts: 0,
              product: p,
              fromTagOnly: true,
            )));
      }
      return result;
    });
  }

  /// Mavsumlar bo'yicha umumiy ko'rsatkich (yil = null bo'lsa — barcha yillar).
  Stream<List<SeasonSummary>> watchSeasonSummaries({int? year}) {
    final where = year == null ? '' : 'WHERE year = ?';
    return db
        .customSelect(
          'SELECT season, COALESCE(SUM(qty),0) q, COALESCE(SUM(revenue),0) r FROM seasonal_stats $where GROUP BY season',
          variables: [if (year != null) Variable.withInt(year)],
          readsFrom: {db.seasonalStats},
        )
        .watch()
        .map((rows) {
      final map = {for (final r in rows) r.read<int>('season'): r};
      return Season.values.map((s) {
        final r = map[s.index0];
        return SeasonSummary(s, r?.read<double>('q') ?? 0, r?.read<int>('r') ?? 0);
      }).toList();
    });
  }

  /// Bir mavsumdagi top tovarlar (mavsumiy statistika sahifasi uchun).
  Stream<List<ProductSales>> watchSeasonTop(Season season, {int? year, int limit = 15}) {
    final yearCond = year == null ? '' : 'AND ss.year = ?';
    return _productSales(
      'SELECT ss.product_id pid, COALESCE(p.name, ss.product_id) n, SUM(ss.qty) q, SUM(ss.revenue) rev, '
      'SUM(ss.sale_count) rc FROM seasonal_stats ss LEFT JOIN products p ON p.id = ss.product_id '
      'WHERE ss.season = ? $yearCond GROUP BY ss.product_id ORDER BY q DESC LIMIT ?',
      [
        Variable.withInt(season.index0),
        if (year != null) Variable.withInt(year),
        Variable.withInt(limit),
      ],
      extraReads: {db.seasonalStats},
    );
  }

  Future<List<int>> seasonYears() async {
    final rows = await db.customSelect('SELECT DISTINCT year FROM seasonal_stats ORDER BY year DESC').get();
    return rows.map((r) => r.read<int>('year')).toList();
  }

  Stream<List<CashierSales>> watchByCashier(DayRange r) {
    return db
        .customSelect(
          'SELECT s.cashier_id id, MAX(s.cashier_name) n, SUM(s.total) t, COUNT(*) c FROM sales s '
          'WHERE $_completed AND s.created_at >= ? AND s.created_at < ? GROUP BY s.cashier_id ORDER BY t DESC',
          variables: [Variable.withInt(r.fromMs), Variable.withInt(r.toMs)],
          readsFrom: {db.sales},
        )
        .watch()
        .map((rows) => rows
            .map((x) => CashierSales(x.read<String>('id'), x.read<String>('n'), x.read<int>('t'), x.read<int>('c')))
            .toList());
  }

  /// Oxirgi N kunlik savdo (grafik uchun). Savdo bo'lmagan kunlar 0 bilan.
  Stream<List<DailyPoint>> watchDaily({int days = 14}) {
    final r = DayRange.lastDays(days);
    return db
        .customSelect(
          "SELECT date(s.created_at / 1000, 'unixepoch', 'localtime') d, SUM(s.total) t, COUNT(*) c "
          'FROM sales s WHERE $_completed AND s.created_at >= ? GROUP BY d',
          variables: [Variable.withInt(r.fromMs)],
          readsFrom: {db.sales},
        )
        .watch()
        .map((rows) {
      final map = {for (final x in rows) x.read<String>('d'): x};
      return List.generate(days, (i) {
        final day = r.from.add(Duration(days: i));
        final key = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
        final x = map[key];
        return DailyPoint(day, x?.read<int>('t') ?? 0, x?.read<int>('c') ?? 0);
      });
    });
  }

  // --------------------------------------------------------------------------
  //  Mavsumiy statistika keshini yangilash
  // --------------------------------------------------------------------------

  /// Bitta sotuv qatorini statistikaga qo'shish (refund uchun manfiy qiymat).
  Future<void> addToSeasonal({
    required String productId,
    required DateTime at,
    required double qty,
    required int revenue,
    int saleCount = 1,
  }) {
    return db.customStatement(
      'INSERT INTO seasonal_stats (product_id, season, year, qty, revenue, sale_count) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(product_id, season, year) DO UPDATE SET qty = qty + excluded.qty, '
      'revenue = revenue + excluded.revenue, sale_count = sale_count + excluded.sale_count',
      [productId, Season.of(at).index0, Season.seasonYear(at), qty, revenue, saleCount],
    ).then((_) => db.notifyUpdates({TableUpdate.onTable(db.seasonalStats)}));
  }

  /// Statistikani barcha sotuvlardan to'liq qayta qurish (sinxronlashdan keyin).
  Future<void> rebuildSeasonal() async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM seasonal_stats');
      await db.customStatement(
        'INSERT INTO seasonal_stats (product_id, season, year, qty, revenue, sale_count) '
        'SELECT si.product_id, $_seasonExpr, $_seasonYearExpr, SUM(si.qty), SUM(si.line_total), '
        'COUNT(DISTINCT si.sale_id) FROM sale_items si JOIN sales s ON s.id = si.sale_id '
        'WHERE $_completed GROUP BY si.product_id, $_seasonExpr, $_seasonYearExpr',
      );
    });
    db.notifyUpdates({TableUpdate.onTable(db.seasonalStats)});
  }

  // --------------------------------------------------------------------------

  Stream<List<ProductSales>> _productSales(String sql, List<Variable> vars,
      {Set<ResultSetImplementation>? extraReads}) {
    return db
        .customSelect(sql, variables: vars, readsFrom: {db.sales, db.saleItems, db.products, ...?extraReads})
        .watch()
        .asyncMap((rows) async {
      final ids = rows.map((r) => r.read<String>('pid'));
      final products = await _productsById(ids);
      return rows
          .map((r) => ProductSales(
                productId: r.read<String>('pid'),
                name: r.read<String>('n'),
                qty: r.read<double>('q'),
                revenue: r.read<int>('rev'),
                receipts: r.read<int>('rc'),
                product: products[r.read<String>('pid')],
              ))
          .toList();
    });
  }

  Future<Map<String, Product>> _productsById(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return {};
    final rows = await (db.select(db.products)..where((p) => p.id.isIn(list) & p.isDeleted.equals(false))).get();
    return {for (final p in rows) p.id: p};
  }
}
