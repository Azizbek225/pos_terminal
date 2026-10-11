import 'package:drift/drift.dart';

import '../../core/security.dart';
import '../database.dart';

/// Tovarlar ro'yxatini filtrlash parametrlari.
class ProductFilter {
  const ProductFilter({
    this.query = '',
    this.categoryId,
    this.lowStockOnly = false,
    this.includeInactive = false,
    this.limit = 500,
  });

  final String query;
  final String? categoryId;
  final bool lowStockOnly;
  final bool includeInactive;
  final int limit;

  @override
  bool operator ==(Object other) =>
      other is ProductFilter &&
      other.query == query &&
      other.categoryId == categoryId &&
      other.lowStockOnly == lowStockOnly &&
      other.includeInactive == includeInactive &&
      other.limit == limit;

  @override
  int get hashCode => Object.hash(query, categoryId, lowStockOnly, includeInactive, limit);
}

/// Tovarlar va kategoriyalar bilan ishlash.
class ProductRepository {
  ProductRepository(this.db, this.deviceId);
  final AppDatabase db;
  final Future<String> Function() deviceId;

  // --------------------------------------------------------------------------
  //  Qidiruv
  // --------------------------------------------------------------------------

  /// Shtrix-kod bo'yicha aniq topish (asosiy yoki qo'shimcha kod).
  Future<Product?> findByBarcode(String code) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    final q = db.select(db.products)
      ..where((p) =>
          p.isDeleted.equals(false) &
          (p.barcode.equals(c) | p.barcode2.equals(c) | p.sku.equals(c)))
      ..limit(1);
    return q.getSingleOrNull();
  }

  /// Tezkor qidiruv: shtrix-kod, artikul, nom, brend yoki kategoriya nomi.
  /// Aniq shtrix-kod/artikul mosligi ro'yxat boshida turadi.
  Future<List<Product>> search(String query, {int limit = 30, String? categoryId}) {
    return _filtered(ProductFilter(query: query, categoryId: categoryId, limit: limit)).get();
  }

  Stream<List<Product>> watch(ProductFilter f) => _filtered(f).watch();

  SimpleSelectStatement<$ProductsTable, Product> _filtered(ProductFilter f) {
    final q = db.select(db.products)..where((p) => p.isDeleted.equals(false));
    if (!f.includeInactive) q.where((p) => p.isActive.equals(true));
    if (f.categoryId != null) q.where((p) => p.categoryId.equals(f.categoryId!));
    if (f.lowStockOnly) {
      q.where((p) => p.minStock.isBiggerThanValue(0) & p.stockQty.isSmallerOrEqual(p.minStock));
    }
    final text = f.query.trim();
    if (text.isNotEmpty) {
      final like = '%${text.replaceAll('%', '').replaceAll('_', '')}%';
      // Kategoriya nomi bo'yicha qidirish uchun subquery.
      final catIds = db.selectOnly(db.categories)
        ..addColumns([db.categories.id])
        ..where(db.categories.name.like(like));
      q.where((p) =>
          p.barcode.equals(text) |
          p.barcode2.equals(text) |
          p.sku.like(like) |
          p.name.like(like) |
          p.shortName.like(like) |
          p.brand.like(like) |
          p.categoryId.isInQuery(catIds));
      q.orderBy([
        (p) => OrderingTerm(
            expression: (p.barcode.equals(text) | p.sku.equals(text)).caseMatch<int>(
                when: {const Constant(true): const Constant(0)}, orElse: const Constant(1))),
        (p) => OrderingTerm(expression: p.name),
      ]);
    } else {
      q.orderBy([(p) => OrderingTerm(expression: p.name)]);
    }
    q.limit(f.limit);
    return q;
  }

  Future<Product?> byId(String id) =>
      (db.select(db.products)..where((p) => p.id.equals(id))).getSingleOrNull();

  Stream<Product?> watchById(String id) =>
      (db.select(db.products)..where((p) => p.id.equals(id))).watchSingleOrNull();

  Future<List<Product>> byIds(Iterable<String> ids) =>
      (db.select(db.products)..where((p) => p.id.isIn(ids))).get();

  /// Minimal qoldiqdan past tovarlar (real-time).
  Stream<List<Product>> watchLowStock() => watch(const ProductFilter(lowStockOnly: true));

  Stream<int> watchCount() {
    final c = db.products.id.count();
    final q = db.selectOnly(db.products)
      ..addColumns([c])
      ..where(db.products.isDeleted.equals(false));
    return q.map((r) => r.read(c) ?? 0).watchSingle();
  }

  // --------------------------------------------------------------------------
  //  Yozish
  // --------------------------------------------------------------------------

  /// Yangi tovar yaratish yoki mavjudini yangilash.
  /// `stockQty` bu yerda o'zgartirilmaydi — u faqat ombor harakatlari orqali o'zgaradi.
  Future<String> save(ProductsCompanion data) async {
    final now = Ids.nowMs();
    final dev = await deviceId();
    final id = data.id.present ? data.id.value : Ids.newId();
    final existing = await byId(id);
    if (existing == null) {
      await db.into(db.products).insert(data.copyWith(
            id: Value(id),
            createdAt: Value(now),
            updatedAt: Value(now),
            version: const Value(1),
            deviceId: Value(dev),
            dirty: const Value(true),
            stockQty: const Value(0),
          ));
    } else {
      await (db.update(db.products)..where((p) => p.id.equals(id))).write(data.copyWith(
            id: const Value.absent(),
            createdAt: const Value.absent(),
            stockQty: const Value.absent(),
            updatedAt: Value(now),
            version: Value(existing.version + 1),
            deviceId: Value(dev),
            dirty: const Value(true),
          ));
    }
    return id;
  }

  /// Yumshoq o'chirish (boshqa qurilmalarga ham sinxronlanadi).
  Future<void> softDelete(String id) async {
    final p = await byId(id);
    if (p == null) return;
    await (db.update(db.products)..where((t) => t.id.equals(id))).write(ProductsCompanion(
      isDeleted: const Value(true),
      isActive: const Value(false),
      updatedAt: Value(Ids.nowMs()),
      version: Value(p.version + 1),
      dirty: const Value(true),
    ));
  }

  /// Shtrix-kod boshqa tovarda band emasligini tekshirish.
  Future<bool> isBarcodeTaken(String code, {String? exceptId}) async {
    if (code.trim().isEmpty) return false;
    final q = db.select(db.products)
      ..where((p) =>
          p.isDeleted.equals(false) & (p.barcode.equals(code) | p.barcode2.equals(code)));
    final rows = await q.get();
    return rows.any((r) => r.id != exceptId);
  }

  /// Ichki EAN-13 shtrix-kod generatsiyasi ("200" prefiksi — do'kon ichki kodlari).
  Future<String> generateInternalBarcode() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final body = '200${(DateTime.now().microsecondsSinceEpoch % 1000000000).toString().padLeft(9, '0')}';
      final code = body + _ean13CheckDigit(body).toString();
      if (!await isBarcodeTaken(code)) return code;
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    throw StateError('Shtrix-kod yaratib bo\'lmadi');
  }

  static int _ean13CheckDigit(String twelve) {
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final d = int.parse(twelve[i]);
      sum += i.isEven ? d : d * 3;
    }
    return (10 - sum % 10) % 10;
  }

  // --------------------------------------------------------------------------
  //  Kategoriyalar
  // --------------------------------------------------------------------------

  Stream<List<ProductCategory>> watchCategories() => (db.select(db.categories)
        ..where((c) => c.isDeleted.equals(false))
        ..orderBy([(c) => OrderingTerm(expression: c.sortOrder), (c) => OrderingTerm(expression: c.name)]))
      .watch();

  Future<List<ProductCategory>> categories() => (db.select(db.categories)
        ..where((c) => c.isDeleted.equals(false))
        ..orderBy([(c) => OrderingTerm(expression: c.sortOrder)]))
      .get();

  Future<String> saveCategory({String? id, required String name, int? color}) async {
    final now = Ids.nowMs();
    final dev = await deviceId();
    if (id == null) {
      final newId = Ids.newId();
      await db.into(db.categories).insert(CategoriesCompanion.insert(
            id: newId,
            name: name,
            color: Value(color ?? 0xFF607D8B),
            createdAt: now,
            updatedAt: now,
            deviceId: Value(dev),
          ));
      return newId;
    }
    final existing =
        await (db.select(db.categories)..where((c) => c.id.equals(id))).getSingle();
    await (db.update(db.categories)..where((c) => c.id.equals(id))).write(CategoriesCompanion(
      name: Value(name),
      color: color == null ? const Value.absent() : Value(color),
      updatedAt: Value(now),
      version: Value(existing.version + 1),
      deviceId: Value(dev),
      dirty: const Value(true),
    ));
    return id;
  }

  Future<void> deleteCategory(String id) async {
    final now = Ids.nowMs();
    await (db.update(db.categories)..where((c) => c.id.equals(id))).write(CategoriesCompanion(
      isDeleted: const Value(true),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
  }
}
