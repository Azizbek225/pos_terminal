import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:pos_terminal/core/branch.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/activity_repository.dart';
import 'package:pos_terminal/data/repositories/alert_repository.dart';
import 'package:pos_terminal/data/repositories/customer_repository.dart';
import 'package:pos_terminal/data/repositories/product_repository.dart';
import 'package:pos_terminal/data/repositories/sale_repository.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/data/repositories/stats_repository.dart';
import 'package:pos_terminal/data/repositories/stock_repository.dart';
import 'package:pos_terminal/data/repositories/user_repository.dart';
import 'package:pos_terminal/services/alert_service.dart';
import 'package:pos_terminal/services/checkout_service.dart';
import 'package:pos_terminal/services/notification_service.dart';

/// Testlar uchun xotiradagi baza va barcha servislar to'plami.
class TestEnv {
  TestEnv() : db = AppDatabase(NativeDatabase.memory()) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    settings = SettingsRepository(db);
    Future<String> dev() => settings.deviceId();
    activity = ActivityRepository(db, dev, branch: branch, currentUser: () => actor);
    products = ProductRepository(db, dev, activity: activity);
    stock = StockRepository(db, dev, branch: branch);
    users = UserRepository(db, dev, branch: branch, activity: activity);
    sales = SaleRepository(db, branch: branch);
    stats = StatsRepository(db, branch: branch);
    alertsRepo = AlertRepository(db);
    customers = CustomerRepository(db, dev, branch: branch, activity: activity);
    alerts = AlertService(
      alerts: alertsRepo,
      products: products,
      sales: sales,
      settings: settings,
      notifications: NotificationService(),
    );
    checkout = CheckoutService(
      db: db,
      settings: settings,
      stock: stock,
      sales: sales,
      stats: stats,
      users: users,
      alerts: alerts,
      customers: customers,
    );
  }

  final AppDatabase db;
  final branch = BranchContext();

  /// Jurnalga yoziladigan "joriy" xodim.
  User? actor;
  late final ActivityRepository activity;
  late final SettingsRepository settings;
  late final ProductRepository products;
  late final StockRepository stock;
  late final UserRepository users;
  late final SaleRepository sales;
  late final StatsRepository stats;
  late final AlertRepository alertsRepo;
  late final AlertService alerts;
  late final CheckoutService checkout;
  late final CustomerRepository customers;

  Future<Product> addProduct(String name, {int price = 10000, int cost = 7000, double stock = 0, double min = 0, String barcode = '', String seasons = ''}) async {
    final id = await products.save(ProductsCompanion(
      name: Value(name),
      salePrice: Value(price),
      purchasePrice: Value(cost),
      minStock: Value(min),
      barcode: Value(barcode),
      seasonTags: Value(seasons),
    ));
    if (stock > 0) {
      final admin = await users.login('admin', 'admin123');
      await this.stock.addMovements([MovementInput(productId: id, type: MovementType.receipt, qty: stock)],
          userId: admin.id, userName: admin.fullName);
    }
    return (await products.byId(id))!;
  }

  Future<void> close() => db.close();
}

