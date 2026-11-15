import 'package:drift/drift.dart';

import '../../core/currency.dart';
import '../../core/formatters.dart';
import '../../core/security.dart';
import '../database.dart';
import 'activity_repository.dart';

/// Dollar kursi: tarix, joriy kurs va dollar narxli tovarlarni kursga moslash.
class CurrencyRepository {
  CurrencyRepository(this.db, this.deviceId, {this.activity});
  final AppDatabase db;
  final Future<String> Function() deviceId;
  final ActivityRepository? activity;

  SimpleSelectStatement<$CurrencyRatesTable, CurrencyRate> _latest() => db.select(db.currencyRates)
    ..where((r) => r.isDeleted.equals(false) & r.currency.equals(Currency.usd.code) & r.rate.isBiggerThanValue(0))
    ..orderBy([(r) => OrderingTerm.desc(r.createdAt), (r) => OrderingTerm.desc(r.id)])
    ..limit(1);

  /// Joriy kurs — eng oxirgi yozilgani (Markaziy bank yoki qo'lda).
  Future<CurrencyRate?> current() => _latest().getSingleOrNull();

  Stream<CurrencyRate?> watchCurrent() => _latest().watchSingleOrNull();

  Stream<List<CurrencyRate>> watchHistory({int limit = 30}) => (db.select(db.currencyRates)
        ..where((r) => r.isDeleted.equals(false) & r.currency.equals(Currency.usd.code))
        ..orderBy([(r) => OrderingTerm.desc(r.createdAt)])
        ..limit(limit))
      .watch();

  /// Kursni yozish. [id] berilsa (Markaziy bank: "cbu-USD-sana") va shu kurs
  /// allaqachon yozilgan bo'lsa — hech narsa qilmaydi (false qaytaradi): tushdan
  /// keyin yana o'sha kurs kelsa, qo'lda kiritilgan kurs ustidan yozib yubormaydi.
  Future<bool> saveRate({
    required double rate,
    String source = 'manual',
    String rateDate = '',
    String? id,
    String userName = '',
  }) async {
    if (rate < 100 || rate > 1000000) throw ArgumentError("Kurs noto'g'ri: $rate");
    final rid = id ?? Ids.newId();
    final old = await (db.select(db.currencyRates)..where((r) => r.id.equals(rid))).getSingleOrNull();
    if (old != null && !old.isDeleted && (old.rate - rate).abs() < 0.005) return false;
    final now = Ids.nowMs();
    await db.into(db.currencyRates).insertOnConflictUpdate(CurrencyRatesCompanion.insert(
          id: rid,
          rate: rate,
          rateDate: Value(rateDate),
          source: Value(source),
          userName: Value(userName),
          createdAt: now,
          updatedAt: now,
          version: Value((old?.version ?? 0) + 1),
          deviceId: Value(await deviceId()),
          isDeleted: const Value(false),
          dirty: const Value(true),
        ));
    if (source == 'manual') {
      await activity?.log('currency_rate', details: "Dollar kursi qo'lda: ${Money.rate(rate)} so'm", global: true);
    }
    return true;
  }

  /// Dollar narxli tovarlarni joriy kursga moslash. Narx faqat OSHADI: kurs
  /// tushsa, tovar qimmat kursda olingan narxida qoladi (zarar bo'lmaydi).
  /// Qaytaradi: narxi o'zgargan tovarlar soni.
  Future<int> applyRate(num rate, {int step = 100}) async {
    final r = rate.round();
    if (r <= 0) return 0;
    final rows = await (db.select(db.products)
          ..where((p) => p.isDeleted.equals(false) & p.salePriceUsd.isBiggerThanValue(0) & p.usdRate.isSmallerThanValue(r)))
        .get();
    if (rows.isEmpty) return 0;
    final now = Ids.nowMs();
    final dev = await deviceId();
    var changed = 0;
    await db.transaction(() async {
      for (final p in rows) {
        final next = Money.usdToSum(p.salePriceUsd, r, step: step);
        final price = next > p.salePrice ? next : p.salePrice;
        if (price != p.salePrice) changed++;
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(ProductsCompanion(
          salePrice: Value(price),
          usdRate: Value(r),
          updatedAt: Value(now),
          version: Value(p.version + 1),
          deviceId: Value(dev),
          dirty: const Value(true),
        ));
      }
    });
    if (changed > 0) {
      await activity?.log('price_changed',
          details: "Dollar kursi ${Fmt.money(r)}: $changed ta dollar narxli tovar narxi oshdi", global: true);
    }
    return changed;
  }
}
