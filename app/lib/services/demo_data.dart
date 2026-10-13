import 'dart:math';

import 'package:drift/drift.dart';

import '../core/constants.dart';
import '../core/season.dart';
import '../core/security.dart';
import '../data/database.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/stats_repository.dart';
import '../data/repositories/stock_repository.dart';
import '../data/repositories/supplier_repository.dart';

/// Tizimni sinab ko'rish uchun namunaviy ma'lumotlar:
/// xo'jalik mollari, mavsum belgilari va oxirgi ~14 oylik sotuvlar tarixi
/// (mavsumiy tavsiyalar va dashboard darhol to'lishi uchun).
class DemoDataService {
  DemoDataService(this.db, this.settings, this.stock, this.stats);
  final AppDatabase db;
  final SettingsRepository settings;
  final StockRepository stock;
  final StatsRepository stats;

  /// (nom, kategoriya, brend, birlik, kirim narxi, sotuv narxi, min qoldiq, mavsumlar)
  static const _items = <(String, String, String, String, int, int, double, String)>[
    ('Elektr isitgich 2 kVt', 'Isitish va sovutish', 'Artel', 'dona', 320000, 420000, 3, 'winter,autumn'),
    ('Moyli radiator 9 seksiya', 'Isitish va sovutish', 'Midea', 'dona', 650000, 820000, 2, 'winter'),
    ('Elektr adyol', 'Isitish va sovutish', 'Beurer', 'dona', 280000, 360000, 2, 'winter'),
    ('Ventilyator stol usti', 'Isitish va sovutish', 'Artel', 'dona', 150000, 210000, 3, 'summer'),
    ('Ventilyator poldagi', 'Isitish va sovutish', 'Midea', 'dona', 260000, 340000, 2, 'summer'),
    ('Pashsha to\'ri (deraza)', 'Plastik buyumlar', 'Mahalliy', 'dona', 18000, 30000, 10, 'spring,summer'),
    ('Chivinga qarshi fumigator', 'Elektr mollari', 'Raptor', 'dona', 22000, 35000, 10, 'summer'),
    ('Bog\' shlangi 20 m', "Bog' va hovli", 'Gardena', 'dona', 95000, 140000, 4, 'spring,summer'),
    ('Bog\' qaychisi', "Bog' va hovli", 'Fiskars', 'dona', 70000, 105000, 3, 'spring,autumn'),
    ('Belkurak', "Bog' va hovli", 'Mahalliy', 'dona', 45000, 70000, 5, 'spring,autumn'),
    ('Xaskash (grabli)', "Bog' va hovli", 'Mahalliy', 'dona', 38000, 60000, 5, 'autumn'),
    ('Qor kuragi', "Bog' va hovli", 'Mahalliy', 'dona', 55000, 85000, 4, 'winter'),
    ('Urug\'lar to\'plami (sabzavot)', "Bog' va hovli", 'Agro', "to'plam", 8000, 15000, 20, 'spring'),
    ('Konservalash bankasi 1 L', 'Oshxona anjomlari', 'Mahalliy', 'dona', 4500, 8000, 50, 'summer,autumn'),
    ('Banka qopqog\'i (10 dona)', 'Oshxona anjomlari', 'Mahalliy', 'paket', 9000, 15000, 30, 'summer,autumn'),
    ('Qozon 10 L', 'Oshxona anjomlari', 'Mahalliy', 'dona', 210000, 290000, 3, ''),
    ('Tova 28 sm', 'Oshxona anjomlari', 'Tefal', 'dona', 180000, 250000, 4, ''),
    ('Choynak elektr 1.7 L', 'Elektr mollari', 'Philips', 'dona', 190000, 260000, 4, ''),
    ('Pichoq to\'plami', 'Oshxona anjomlari', 'Tramontina', "to'plam", 120000, 175000, 3, ''),
    ('Piyola (6 dona)', 'Oshxona anjomlari', 'Mahalliy', "to'plam", 35000, 55000, 6, ''),
    ('Idish yuvish vositasi 1 L', 'Tozalash vositalari', 'Fairy', 'dona', 18000, 26000, 20, ''),
    ('Kir yuvish kukuni 3 kg', 'Tozalash vositalari', 'Ariel', 'dona', 65000, 85000, 10, ''),
    ('Oqartiruvchi 1 L', 'Tozalash vositalari', 'Belizna', 'dona', 9000, 14000, 15, 'spring'),
    ('Pol yuvish vositasi', 'Tozalash vositalari', 'Mr. Proper', 'dona', 22000, 32000, 10, 'spring'),
    ('Shvabra (mop)', 'Tozalash vositalari', 'Vileda', 'dona', 75000, 110000, 4, 'spring'),
    ('Chelak 12 L', 'Plastik buyumlar', 'Mahalliy', 'dona', 16000, 25000, 10, ''),
    ('Tog\'ora 30 L', 'Plastik buyumlar', 'Mahalliy', 'dona', 28000, 42000, 6, 'summer'),
    ('Konteyner to\'plami', 'Plastik buyumlar', 'Mahalliy', "to'plam", 30000, 48000, 6, ''),
    ('Axlat paketi 60 L (20 dona)', 'Plastik buyumlar', 'Mahalliy', 'paket', 9000, 14000, 30, ''),
    ('LED lampa 12 Vt', 'Elektr mollari', 'Philips', 'dona', 14000, 22000, 30, 'autumn,winter'),
    ('Uzaytirgich 5 m', 'Elektr mollari', 'Mahalliy', 'dona', 38000, 55000, 8, 'winter'),
    ('Batareyka AA (4 dona)', 'Elektr mollari', 'Duracell', 'paket', 16000, 25000, 20, ''),
    ('Sochiq 70x140', "Uy to'qimachiligi", 'Mahalliy', 'dona', 45000, 70000, 6, 'summer'),
    ('Adyol 2 kishilik', "Uy to'qimachiligi", 'Mahalliy', 'dona', 220000, 310000, 3, 'autumn,winter'),
    ('Gilam yo\'lak (metr)', "Uy to'qimachiligi", 'Mahalliy', 'metr', 40000, 60000, 10, 'autumn'),
    ('Tish pastasi', 'Hammom va gigiyena', 'Colgate', 'dona', 12000, 18000, 20, ''),
    ('Hojatxona qog\'ozi (4 rulon)', 'Hammom va gigiyena', 'Zewa', 'paket', 14000, 20000, 25, ''),
    ('Dush pardasi', 'Hammom va gigiyena', 'Mahalliy', 'dona', 35000, 55000, 4, ''),
    ('Bolg\'a', 'Asbob-uskunalar', 'Stanley', 'dona', 50000, 75000, 4, ''),
    ('Otvertka to\'plami', 'Asbob-uskunalar', 'Stanley', "to'plam", 60000, 90000, 4, ''),
    ('Mixlar 1 kg', 'Asbob-uskunalar', 'Mahalliy', 'kg', 18000, 28000, 10, 'spring'),
    ('Deraza uchun izolyatsiya lentasi', 'Asbob-uskunalar', 'Mahalliy', 'rulon', 12000, 20000, 15, 'autumn,winter'),
  ];

  Future<int> load(User admin) async {
    final rnd = Random(42);
    final now = DateTime.now();
    final dev = await settings.deviceId();
    final cats = await db.select(db.categories).get();
    final catByName = {for (final c in cats) c.name: c.id};
    final products = <Product>[];
    final stockMap = <String, double>{};

    await db.transaction(() async {
      var n = 0;
      for (final it in _items) {
        n++;
        final id = Ids.newId();
        final body = '478${(100000000 + n * 7919).toString().substring(0, 9)}';
        final barcode = body + _check(body).toString();
        final p = Product(
          id: id,
          sku: 'XM-${n.toString().padLeft(4, '0')}',
          barcode: barcode,
          barcode2: '',
          name: it.$1,
          shortName: '',
          description: '',
          categoryId: catByName[it.$2],
          brand: it.$3,
          manufacturer: it.$3,
          country: it.$3 == 'Mahalliy' ? "O'zbekiston" : '',
          supplier: '',
          mxikCode: '',
          packageCode: '',
          vatPercent: 12,
          unit: it.$4,
          packQty: 1,
          isWeighted: it.$4 == 'kg' || it.$4 == 'metr',
          purchasePrice: it.$5,
          salePrice: it.$6,
          wholesalePrice: (it.$6 * 0.93).round(),
          stockQty: 0,
          minStock: it.$7,
          maxStock: 0,
          location: 'R${1 + n % 6}-${1 + n % 4}',
          color: '',
          size: '',
          material: '',
          weightKg: 0,
          volumeL: 0,
          warrantyMonths: it.$4 == 'dona' && it.$2 == 'Elektr mollari' ? 12 : 0,
          seasonTags: it.$8,
          isActive: true,
          imagePath: '',
          notes: '',
          createdAt: now.subtract(const Duration(days: 420)).millisecondsSinceEpoch,
          updatedAt: Ids.nowMs(),
          version: 1,
          deviceId: dev,
          isDeleted: false,
          dirty: true,
        );
        await db.into(db.products).insert(p);
        products.add(p);
        // Boshlang'ich kirim (tarix boshida).
        final initial = 40 + rnd.nextInt(160).toDouble();
        stockMap[id] = initial;
        await db.into(db.stockMovements).insert(StockMovementsCompanion.insert(
              id: Ids.newId(),
              productId: id,
              type: MovementType.receipt.code,
              qty: initial,
              unitCost: Value(it.$5),
              note: const Value('Demo: boshlang\'ich kirim'),
              userId: Value(admin.id),
              userName: Value(admin.fullName),
              createdAt: p.createdAt,
              updatedAt: p.createdAt,
              deviceId: Value(dev),
            ));
      }

      // ~14 oylik sotuvlar: mavsum tovarlari o'z mavsumida 4 barobar ko'proq sotiladi.
      var seq = await settings.getInt(SettingKeys.receiptSeq, 0);
      final prefix = (await settings.get(SettingKeys.deviceCode)) ?? 'K1';
      for (var d = 420; d >= 0; d--) {
        final day = DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
        final season = Season.of(day);
        final salesToday = 3 + rnd.nextInt(6);
        for (var s = 0; s < salesToday; s++) {
          final at = day.add(Duration(hours: 9 + rnd.nextInt(10), minutes: rnd.nextInt(60)));
          if (at.isAfter(now)) continue;
          final lineCount = 1 + rnd.nextInt(4);
          final picked = <Product>{};
          while (picked.length < lineCount) {
            final p = products[rnd.nextInt(products.length)];
            final tags = parseSeasonTags(p.seasonTags);
            final weight = tags.isEmpty ? 2 : (tags.contains(season) ? 5 : 0);
            if (rnd.nextInt(5) < weight) picked.add(p);
          }
          final saleId = Ids.newId();
          final ms = at.millisecondsSinceEpoch;
          var subtotal = 0;
          var cost = 0;
          var count = 0.0;
          final items = <SaleItemsCompanion>[];
          final moves = <StockMovementsCompanion>[];
          var i = 0;
          for (final p in picked) {
            final qty = (1 + rnd.nextInt(p.salePrice < 30000 ? 4 : 2)).toDouble();
            // Qoldiq yetmasa — sotuvdan oldin yetkazib beruvchidan kirim.
            // Oxirgi 10 kunda to'ldirilmaydi: ba'zi tovarlar kam qolib, alert chiqadi.
            if ((stockMap[p.id] ?? 0) < qty && d > 10) {
              final add = 60 + rnd.nextInt(100).toDouble();
              stockMap[p.id] = (stockMap[p.id] ?? 0) + add;
              await db.into(db.stockMovements).insert(StockMovementsCompanion.insert(
                    id: Ids.newId(),
                    productId: p.id,
                    type: MovementType.receipt.code,
                    qty: add,
                    unitCost: Value(p.purchasePrice),
                    note: const Value('Demo: kirim'),
                    userId: Value(admin.id),
                    userName: Value(admin.fullName),
                    createdAt: ms - 3600000,
                    updatedAt: ms - 3600000,
                    deviceId: Value(dev),
                  ));
            }
            if ((stockMap[p.id] ?? 0) < qty) continue;
            stockMap[p.id] = stockMap[p.id]! - qty;
            final total = (qty * p.salePrice).round();
            subtotal += total;
            cost += (qty * p.purchasePrice).round();
            count += qty;
            items.add(SaleItemsCompanion.insert(
              id: Ids.newId(),
              saleId: saleId,
              productId: p.id,
              productName: p.name,
              barcode: Value(p.barcode),
              unit: Value(p.unit),
              qty: qty,
              price: p.salePrice,
              purchasePrice: Value(p.purchasePrice),
              lineTotal: total,
              createdAt: ms + i++,
              updatedAt: ms,
              deviceId: Value(dev),
            ));
            moves.add(StockMovementsCompanion.insert(
              id: Ids.newId(),
              productId: p.id,
              type: MovementType.sale.code,
              qty: -qty,
              unitCost: Value(p.purchasePrice),
              refId: Value(saleId),
              userId: Value(admin.id),
              userName: Value(admin.fullName),
              createdAt: ms,
              updatedAt: ms,
              deviceId: Value(dev),
            ));
          }
          if (items.isEmpty) continue;
          seq++;
          final payType = [PaymentType.cash, PaymentType.cash, PaymentType.card, PaymentType.transfer][rnd.nextInt(4)];
          await db.into(db.sales).insert(SalesCompanion.insert(
                id: saleId,
                receiptNo: '$prefix-${seq.toString().padLeft(6, '0')}',
                cashierId: admin.id,
                cashierName: admin.fullName,
                subtotal: subtotal,
                total: subtotal,
                paymentType: payType.code,
                paidCash: Value(payType == PaymentType.cash ? subtotal : 0),
                paidCard: Value(payType == PaymentType.card ? subtotal : 0),
                paidTransfer: Value(payType == PaymentType.transfer ? subtotal : 0),
                itemCount: Value(count),
                costTotal: Value(cost),
                createdAt: ms,
                updatedAt: ms,
                deviceId: Value(dev),
              ));
          for (final it in items) {
            await db.into(db.saleItems).insert(it);
          }
          for (final m in moves) {
            await db.into(db.stockMovements).insert(m);
          }
        }
      }
      await settings.set(SettingKeys.receiptSeq, '$seq');
    });

    await stock.recompute();
    await stats.rebuildSeasonal();
    await _demoSuppliers(admin, products, now);
    return products.length;
  }

  /// Namunaviy firmalar: kirimlar, qisman to'lovlar va qarz.
  Future<void> _demoSuppliers(User admin, List<Product> products, DateTime now) async {
    final repo = SupplierRepository(db, settings.deviceId);
    final existing = {for (final s in await repo.allSuppliers()) s.name};
    Future<void> firm(String name, String phone, bool Function(Product) filter, List<(int, double)> docs) async {
      if (existing.contains(name)) return; // demo qayta yuklansa takrorlanmasin
      final id = await repo.saveSupplier(name: name, phone: phone, note: 'Demo');
      final goods = products.where(filter).toList();
      for (final (daysAgo, paidShare) in docs) {
        final lines = [
          for (var i = 0; i < goods.length; i++)
            PurchaseLineInput(
              productId: goods[i].id,
              productName: goods[i].name,
              barcode: goods[i].barcode,
              unit: goods[i].unit,
              qty: (10 + (i * 7 + daysAgo) % 30).toDouble(),
              price: goods[i].purchasePrice,
            ),
        ];
        final total = lines.fold<int>(0, (s, l) => s + l.lineTotal);
        await repo.createPurchase(
          supplierId: id,
          lines: lines,
          docNo: '${100 + daysAgo}',
          docDate: now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch,
          paidNow: (total * paidShare / 1000).round() * 1000,
          note: 'Demo',
          userId: admin.id,
          userName: admin.fullName,
        );
      }
    }

    final cats = {for (final c in await db.select(db.categories).get()) c.id: c.name};
    bool inCats(Product p, Set<String> names) => names.contains(cats[p.categoryId]);
    await firm("Gigiena Savdo MChJ", '+998 90 123 45 67',
        (p) => inCats(p, {'Hammom va gigiyena', 'Tozalash vositalari'}), [(40, 1), (12, 0.5), (2, 0.3)]);
    await firm('Artel Distribyutor', '+998 71 200 00 00',
        (p) => p.brand == 'Artel' || p.brand == 'Midea', [(25, 1), (5, 0.6)]);
    await firm("Plastmass Zavodi", '+998 93 555 11 22',
        (p) => inCats(p, {'Plastik buyumlar'}), [(18, 1)]);
  }

  static int _check(String twelve) {
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = int.parse(twelve[i]);
      sum += i.isEven ? d : d * 3;
    }
    return (10 - sum % 10) % 10;
  }
}
