import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/security.dart';

part 'database.g.dart';

// ============================================================================
//  MA'LUMOTLAR BAZASI SXEMASI (Drift / SQLite)
// ----------------------------------------------------------------------------
//  Tamoyillar:
//  * Har bir sinxronlanadigan jadvalda `id` — UUID (matn). Bir nechta qurilma
//    offline holda yozuv yaratganda ID to'qnashuvi bo'lmaydi.
//  * Vaqtlar millisekund (epoch, int) ko'rinishida — server bilan oson taqqoslash.
//  * `updatedAt` + `version` — konfliktlarni "oxirgi yozuv yutadi" (LWW)
//    tamoyili bo'yicha hal qilish uchun.
//  * `isDeleted` — "yumshoq o'chirish": o'chirish ham boshqa qurilmalarga
//    sinxronlanishi kerak.
//  * `dirty` — faqat lokal: serverga hali yuborilmagan o'zgarish bor.
//  * Qoldiq (stock) hech qachon to'g'ridan-to'g'ri sinxronlanmaydi: u
//    `stock_movements` (o'zgarmas harakatlar) yig'indisidan hisoblanadi.
//    Shuning uchun ikki qurilmada bir vaqtda sotuv bo'lsa ham qoldiq to'g'ri
//    qo'shiladi — konflikt yo'q.
// ============================================================================

/// Barcha sinxronlanadigan jadvallar uchun umumiy ustunlar.
mixin SyncColumns on Table {
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
}

/// Filiallar (do'konlar). Tovarlar va shtrix-kodlar hamma filialda umumiy,
/// savdo, ombor qoldig'i, kirimlar va jurnal esa har bir filialda alohida.
@DataClassName('Branch')
class Branches extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Foydalanuvchilar (Admin, Kassir, Omborchi).
@DataClassName('User')
class Users extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get username => text().unique()();
  TextColumn get fullName => text()();
  TextColumn get role => text()(); // UserRole.code
  TextColumn get passwordHash => text()();
  TextColumn get salt => text()();
  TextColumn get phone => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get lastLoginAt => integer().nullable()();

  /// Filiallardagi ruxsatlar: JSON `{"<filial_id>": "cashier", ...}`.
  /// Bo'sh — asosiy `role` barcha filiallarda amal qiladi.
  TextColumn get branchRoles => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tovar kategoriyalari (daraxtsimon: parentId orqali).
@DataClassName('ProductCategory')
class Categories extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();
  IntColumn get color => integer().withDefault(const Constant(0xFF607D8B))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tovarlar — xo'jalik mollari do'koni uchun standart atributlar to'plami.
@DataClassName('Product')
class Products extends Table with SyncColumns {
  TextColumn get id => text()();

  // --- Identifikatsiya ---
  TextColumn get sku => text().withDefault(const Constant(''))(); // Artikul
  TextColumn get barcode => text().withDefault(const Constant(''))(); // EAN-13 / EAN-8 / UPC / Code128
  TextColumn get barcode2 => text().withDefault(const Constant(''))(); // Qo'shimcha shtrix-kod (qadoq)
  TextColumn get name => text()(); // To'liq nomi
  TextColumn get shortName => text().withDefault(const Constant(''))(); // Chek uchun qisqa nom
  TextColumn get description => text().withDefault(const Constant(''))();

  // --- Tasnif ---
  TextColumn get categoryId => text().nullable()();
  TextColumn get brand => text().withDefault(const Constant(''))();
  TextColumn get manufacturer => text().withDefault(const Constant(''))();
  TextColumn get country => text().withDefault(const Constant(''))(); // Ishlab chiqarilgan mamlakat
  TextColumn get supplier => text().withDefault(const Constant(''))(); // Yetkazib beruvchi

  // --- Soliq (O'zbekiston fiskal talablari) ---
  TextColumn get mxikCode => text().withDefault(const Constant(''))(); // MXIK (IKPU) kodi
  TextColumn get packageCode => text().withDefault(const Constant(''))(); // Qadoq / o'lchov birligi kodi
  RealColumn get vatPercent => real().withDefault(const Constant(12))(); // QQS %

  // --- O'lchov ---
  TextColumn get unit => text().withDefault(const Constant('dona'))();
  RealColumn get packQty => real().withDefault(const Constant(1))(); // Qadoqdagi soni
  BoolColumn get isWeighted => boolean().withDefault(const Constant(false))(); // Tarozida tortiladimi

  // --- Narxlar (so'm, butun son) ---
  IntColumn get purchasePrice => integer().withDefault(const Constant(0))(); // Kirim narxi
  IntColumn get salePrice => integer().withDefault(const Constant(0))(); // Sotuv narxi
  IntColumn get wholesalePrice => integer().withDefault(const Constant(0))(); // Ulgurji narx

  // --- Ombor ---
  /// Joriy qoldiq — `stock_movements` yig'indisining keshi (sinxronlanmaydi).
  RealColumn get stockQty => real().withDefault(const Constant(0))();
  RealColumn get minStock => real().withDefault(const Constant(0))(); // Minimal qoldiq (alert chegarasi)
  RealColumn get maxStock => real().withDefault(const Constant(0))(); // Maksimal qoldiq (0 = cheklanmagan)
  TextColumn get location => text().withDefault(const Constant(''))(); // Javon / qator

  // --- Fizik xususiyatlar ---
  TextColumn get color => text().withDefault(const Constant(''))();
  TextColumn get size => text().withDefault(const Constant(''))(); // O'lcham (masalan 30x40 sm)
  TextColumn get material => text().withDefault(const Constant(''))(); // Plastik, metall, shisha...
  RealColumn get weightKg => real().withDefault(const Constant(0))();
  RealColumn get volumeL => real().withDefault(const Constant(0))();
  IntColumn get warrantyMonths => integer().withDefault(const Constant(0))();

  // --- Mavsumiylik ---
  /// Vergul bilan ajratilgan mavsum kodlari: "winter,autumn". Bo'sh = barcha mavsum.
  TextColumn get seasonTags => text().withDefault(const Constant(''))();

  // --- Holat ---
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get imagePath => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Cheklar (savdo).
@DataClassName('Sale')
class Sales extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get receiptNo => text()(); // Masalan: K1-000123
  TextColumn get cashierId => text()();
  TextColumn get cashierName => text()();
  IntColumn get subtotal => integer()(); // Chegirmagacha summa
  TextColumn get discountType => text().withDefault(const Constant('none'))(); // none | percent | amount
  RealColumn get discountValue => real().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))();
  TextColumn get discountApprovedBy => text().nullable()(); // >20% bo'lsa Admin ID
  IntColumn get total => integer()(); // To'lanadigan summa
  TextColumn get paymentType => text()(); // PaymentType.code
  IntColumn get paidCash => integer().withDefault(const Constant(0))();
  IntColumn get paidCard => integer().withDefault(const Constant(0))();
  IntColumn get paidTransfer => integer().withDefault(const Constant(0))();
  IntColumn get changeAmount => integer().withDefault(const Constant(0))(); // Qaytim
  RealColumn get itemCount => real().withDefault(const Constant(0))();
  IntColumn get costTotal => integer().withDefault(const Constant(0))(); // Tannarx (foyda hisobi uchun)
  TextColumn get status => text().withDefault(const Constant('completed'))();
  IntColumn get refundedAt => integer().nullable()();
  TextColumn get refundedBy => text().nullable()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))(); // Filial (eski yozuvlar — asosiy)

  /// Nasiya: summaning qarzga yozilgan qismi va qarzdor mijoz.
  IntColumn get debtAmount => integer().withDefault(const Constant(0))();
  TextColumn get customerId => text().withDefault(const Constant(''))();
  TextColumn get customerName => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Chek qatorlari. Tovar nomi/narxi nusxalanadi — keyin tovar o'zgarsa ham
/// eski chek o'zgarmaydi.
@DataClassName('SaleItem')
class SaleItems extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get productId => text()();
  TextColumn get productName => text()();
  TextColumn get barcode => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('dona'))();
  RealColumn get qty => real()();
  IntColumn get price => integer()(); // Birlik narxi
  IntColumn get purchasePrice => integer().withDefault(const Constant(0))();
  IntColumn get discountAmount => integer().withDefault(const Constant(0))(); // Chek chegirmasidan ulush
  IntColumn get lineTotal => integer()(); // qty*price - discount

  @override
  Set<Column> get primaryKey => {id};
}

/// Ombor harakatlari — o'zgarmas jurnal. Qoldiq = SUM(qty).
@DataClassName('StockMovement')
class StockMovements extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get productId => text()();
  TextColumn get type => text()(); // MovementType.code
  RealColumn get qty => real()(); // Ishorali: + kirim, - chiqim
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  TextColumn get refId => text().nullable()(); // Masalan: sotuv ID
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))(); // Filial (eski yozuvlar — asosiy)

  @override
  Set<Column> get primaryKey => {id};
}

/// Mavsumiy statistika — sotuvlardan hisoblanadigan agregat (lokal kesh).
/// Har bir qurilma o'z nusxasini sotuvlar (shu jumladan sinxronlanganlari)
/// asosida qayta quradi.
@DataClassName('SeasonalStat')
class SeasonalStats extends Table {
  TextColumn get productId => text()();
  IntColumn get season => integer()(); // Season.index0
  IntColumn get year => integer()(); // Mavsum yili
  RealColumn get qty => real().withDefault(const Constant(0))();
  IntColumn get revenue => integer().withDefault(const Constant(0))();
  IntColumn get saleCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {productId, season, year};
}

/// Ogohlantirishlar (lokal).
@DataClassName('Alert')
class Alerts extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // AlertType.code
  TextColumn get severity => text()(); // AlertSeverity.code
  TextColumn get title => text()();
  TextColumn get message => text()();
  TextColumn get refId => text().nullable()();
  /// Bir xil ogohlantirish qayta-qayta yaratilmasligi uchun kalit.
  TextColumn get dedupeKey => text().nullable()();
  BoolColumn get isRead => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Audit jurnali: chegirma tasdiqlari, qaytarishlar, login va h.k.
@DataClassName('AuditEntry')
class AuditLog extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get userName => text()();
  TextColumn get action => text()();
  TextColumn get details => text().withDefault(const Constant(''))();

  /// Bo'sh — umumiy o'zgarish (tovar, kategoriya, xodim); aks holda filial ID si.
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))(); // Filial (eski yozuvlar — asosiy)

  /// Tegishli yozuv (masalan tovar ID si).
  TextColumn get refId => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Yetkazib beruvchi firmalar.
@DataClassName('Supplier')
class Suppliers extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get contactPerson => text().withDefault(const Constant(''))(); // Agent / vakil
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Firmadan kirim (nakladnoy). `kind`: purchase — tovar kirimi,
/// opening — boshlang'ich qarz (tovarsiz). Qarz = SUM(total) - SUM(to'lovlar).
@DataClassName('SupplierPurchase')
class SupplierPurchases extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get supplierId => text()();
  TextColumn get supplierName => text().withDefault(const Constant(''))(); // nusxa
  TextColumn get kind => text().withDefault(const Constant('purchase'))();
  TextColumn get docNo => text().withDefault(const Constant(''))(); // Nakladnoy raqami
  IntColumn get docDate => integer()(); // Kirim sanasi (ms)
  IntColumn get total => integer().withDefault(const Constant(0))();
  RealColumn get itemCount => real().withDefault(const Constant(0))();
  /// Prays-list / nakladnoy suratlari: vergul bilan ajratilgan fayl nomlari.
  TextColumn get imagePaths => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))(); // Filial (eski yozuvlar — asosiy)

  @override
  Set<Column> get primaryKey => {id};
}

/// Kirim qatorlari (o'zgarmas). Nom va narx nusxalanadi.
@DataClassName('SupplierPurchaseItem')
class SupplierPurchaseItems extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get purchaseId => text()();
  TextColumn get productId => text()();
  TextColumn get productName => text()();
  TextColumn get barcode => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('dona'))();
  RealColumn get qty => real()();
  IntColumn get price => integer()(); // Kirim narxi (birlik)
  IntColumn get lineTotal => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Firmaga to'lovlar (qarzni uzish). `purchaseId` — ixtiyoriy, qaysi kirim
/// paytida to'langani (ma'lumot uchun; qarz umumiy balansdan hisoblanadi).
@DataClassName('SupplierPayment')
class SupplierPayments extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get supplierId => text()();
  TextColumn get purchaseId => text().nullable()();
  IntColumn get amount => integer()();
  TextColumn get method => text().withDefault(const Constant('cash'))(); // PaymentType.code
  IntColumn get paidAt => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();

  /// Pulni olgan agent ismi va uning ekranga chizilgan imzosi (PNG fayl nomi).
  TextColumn get receivedBy => text().withDefault(const Constant(''))();
  TextColumn get signaturePath => text().withDefault(const Constant(''))();
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))(); // Filial (eski yozuvlar — asosiy)

  @override
  Set<Column> get primaryKey => {id};
}

/// Mijozlar (nasiyaga oluvchilar). Barcha filiallarda umumiy.
class Customers extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Mijoz qarzi daftari. `amount` > 0 — qarz oshdi (nasiya savdo, qo'lda
/// yozilgan qarz), < 0 — kamaydi (to'lov, chek qaytarilishi).
/// Qarz = SUM(amount) (filial bo'yicha).
@DataClassName('CustomerDebt')
class CustomerDebts extends Table with SyncColumns {
  TextColumn get id => text()();
  TextColumn get customerId => text()();
  TextColumn get kind => text()(); // CustomerDebtKind.code
  IntColumn get amount => integer()();
  TextColumn get saleId => text().withDefault(const Constant(''))();
  TextColumn get method => text().withDefault(const Constant(''))(); // to'lov turi (PaymentType.code)
  TextColumn get note => text().withDefault(const Constant(''))();
  TextColumn get userId => text().withDefault(const Constant(''))();
  TextColumn get userName => text().withDefault(const Constant(''))();
  TextColumn get branchId => text().withDefault(const Constant(kDefaultBranchId))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Kalit-qiymat sozlamalar (lokal).
@DataClassName('Setting')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [
  Branches,
  Users,
  Categories,
  Products,
  Sales,
  SaleItems,
  StockMovements,
  SeasonalStats,
  Alerts,
  AuditLog,
  Settings,
  Suppliers,
  SupplierPurchases,
  SupplierPurchaseItems,
  SupplierPayments,
  Customers,
  CustomerDebts,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 6;

  /// Baza fayli ilovaning shaxsiy papkasida saqlanadi (Hujjatlar papkasida emas —
  /// foydalanuvchi tasodifan o'chirib yubormasligi va bulutli sinxronlash
  /// faylni buzmasligi uchun):
  ///  * Windows: %APPDATA%\uz.posterminal\pos_terminal\pos_terminal.sqlite
  ///  * macOS:   ~/Library/Application Support/uz.posterminal.posTerminal/
  ///  * Linux:   ~/.local/share/uz.posterminal.pos_terminal/
  ///  * Android/iOS: ilovaning ichki xotirasi.
  static QueryExecutor _openConnection() => driftDatabase(
        name: 'pos_terminal',
        native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
      );

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
          await _seed();
        },
        onUpgrade: (m, from, to) async {
          // Har bir qadam qayta bajarilsa ham xato bermaydi: yangilash avval
          // yarim yo'lda to'xtagan bo'lsa (ilova yopilgan, xato) — jadval yoki
          // ustun allaqachon bor bo'lishi mumkin.
          // v2: firmalar, kirim hujjatlari va qarzlar.
          for (final t in <TableInfo>[suppliers, supplierPurchases, supplierPurchaseItems, supplierPayments]) {
            if (!await _tableExists(t.actualTableName)) await m.createTable(t);
          }
          // v3: to'lovda agent ismi va imzosi.
          for (final c in [supplierPayments.receivedBy, supplierPayments.signaturePath]) {
            if (!await _columnExists('supplier_payments', c.name)) await m.addColumn(supplierPayments, c);
          }
          // v4: filiallar. Mavjud savdo, qoldiq va kirimlar asosiy filialga o'tadi
          // (ustunning standart qiymati).
          if (!await _tableExists('branches')) await m.createTable(branches);
          if (!await _columnExists('users', 'branch_roles')) await m.addColumn(users, users.branchRoles);
          for (final (t, c) in <(TableInfo, GeneratedColumn)>[
            (sales, sales.branchId),
            (stockMovements, stockMovements.branchId),
            (auditLog, auditLog.branchId),
            (auditLog, auditLog.refId),
            (supplierPurchases, supplierPurchases.branchId),
            (supplierPayments, supplierPayments.branchId),
          ]) {
            if (!await _columnExists(t.actualTableName, c.name)) await m.addColumn(t, c);
          }
          await _seedDefaultBranch();
          // v5: mijozlar va nasiya.
          for (final t in <TableInfo>[customers, customerDebts]) {
            if (!await _tableExists(t.actualTableName)) await m.createTable(t);
          }
          for (final c in [sales.debtAmount, sales.customerId, sales.customerName]) {
            if (!await _columnExists('sales', c.name)) await m.addColumn(sales, c);
          }
          // v6: sinxronlash uchun "yuborilmagan" yozuvlar indeksi (_createIndexes).
          await _createIndexes();
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // WAL — bir vaqtda o'qish/yozishda tezlik.
          await customStatement('PRAGMA journal_mode = WAL');
          // WAL bilan xavfsiz; har commit'da diskka to'liq yozmaydi — ko'p yozuvli
          // sinxronlash bir necha barobar tez.
          await customStatement('PRAGMA synchronous = NORMAL');
        },
      );

  Future<bool> _tableExists(String name) async {
    final r = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return r.isNotEmpty;
  }

  Future<bool> _columnExists(String table, String column) async {
    final r = await customSelect('PRAGMA table_info($table)').get();
    return r.any((row) => row.read<String>('name') == column);
  }

  /// Qidiruv va hisobotlar tez ishlashi uchun indekslar.
  Future<void> _createIndexes() async {
    const stmts = [
      'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode)',
      'CREATE INDEX IF NOT EXISTS idx_products_barcode2 ON products(barcode2)',
      'CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku)',
      'CREATE INDEX IF NOT EXISTS idx_products_name ON products(name COLLATE NOCASE)',
      'CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id)',
      'CREATE INDEX IF NOT EXISTS idx_sales_created ON sales(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_sales_cashier ON sales(cashier_id)',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id)',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_movements_product ON stock_movements(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_movements_created ON stock_movements(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_alerts_created ON alerts(created_at)',
      'CREATE INDEX IF NOT EXISTS idx_alerts_dedupe ON alerts(dedupe_key)',
      'CREATE INDEX IF NOT EXISTS idx_purchases_supplier ON supplier_purchases(supplier_id, doc_date)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON supplier_purchase_items(purchase_id)',
      'CREATE INDEX IF NOT EXISTS idx_purchase_items_product ON supplier_purchase_items(product_id)',
      'CREATE INDEX IF NOT EXISTS idx_supplier_payments_supplier ON supplier_payments(supplier_id, paid_at)',
      'CREATE INDEX IF NOT EXISTS idx_sales_branch ON sales(branch_id, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_customer_debts_customer ON customer_debts(customer_id, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_movements_branch ON stock_movements(branch_id, product_id)',
      'CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at)',
    ];
    for (final s in stmts) {
      await customStatement(s);
    }
    // Faqat yuborilmagan (dirty) yozuvlar: katta bazada ham sinxronlash va
    // "yuborilmagan: N" hisobi butun jadvalni o'qimaydi.
    for (final t in SyncEntities.all) {
      await customStatement('CREATE INDEX IF NOT EXISTS idx_${t}_dirty ON $t(updated_at, id) WHERE dirty = 1');
    }
  }

  /// Standart Admin ning doimiy ID si. Barcha qurilmalarda bir xil bo'lgani
  /// uchun sinxronlashda "ikkita admin" paydo bo'lmaydi.
  static const defaultAdminId = '00000000-0000-4000-8000-000000000001';

  /// Birinchi ishga tushirishda: standart Admin va asosiy kategoriyalar.
  /// ID lar deterministik, `updatedAt = 1` — istalgan haqiqiy o'zgarish
  /// (masalan, parolni almashtirish) sinxronlashda ustun keladi.
  /// Asosiy filial (ID hamma qurilmada bir xil, `updatedAt = 1`).
  Future<void> _seedDefaultBranch() async {
    await into(branches).insert(
      BranchesCompanion.insert(
        id: kDefaultBranchId,
        name: 'Asosiy filial',
        createdAt: 1,
        updatedAt: 1,
        dirty: const Value(false),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> _seed() async {
    const seedTime = 1;
    await _seedDefaultBranch();
    final salt = PasswordHasher.newSalt();
    await into(users).insert(UsersCompanion.insert(
      id: defaultAdminId,
      username: 'admin',
      fullName: 'Administrator',
      role: UserRole.admin.code,
      passwordHash: PasswordHasher.hash('admin123', salt),
      salt: salt,
      createdAt: seedTime,
      updatedAt: seedTime,
      dirty: const Value(false),
    ));

    const cats = <(String, int)>[
      ('Oshxona anjomlari', 0xFFEF6C00),
      ('Tozalash vositalari', 0xFF0288D1),
      ('Plastik buyumlar', 0xFF7CB342),
      ('Elektr mollari', 0xFFFBC02D),
      ('Hammom va gigiyena', 0xFF26A69A),
      ("Bog' va hovli", 0xFF388E3C),
      ('Isitish va sovutish', 0xFFD32F2F),
      ('Asbob-uskunalar', 0xFF5D4037),
      ("Uy to'qimachiligi", 0xFF8E24AA),
      ('Boshqa', 0xFF607D8B),
    ];
    var order = 0;
    for (final c in cats) {
      order++;
      await into(categories).insert(CategoriesCompanion.insert(
        id: '00000000-0000-4000-8000-1000000000${order.toString().padLeft(2, '0')}',
        name: c.$1,
        color: Value(c.$2),
        sortOrder: Value(order),
        createdAt: seedTime,
        updatedAt: seedTime,
        dirty: const Value(false),
      ));
    }
  }
}
