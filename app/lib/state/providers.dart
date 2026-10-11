import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/formatters.dart';
import '../core/season.dart';
import '../data/database.dart';
import '../data/repositories/alert_repository.dart';
import '../data/repositories/product_repository.dart';
import '../data/repositories/sale_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/stats_repository.dart';
import '../data/repositories/stock_repository.dart';
import '../data/repositories/user_repository.dart';
import '../services/alert_service.dart';
import '../services/checkout_service.dart';
import '../services/notification_service.dart';
import '../services/printing/printer_service.dart';
import '../services/sync/sync_service.dart';
import 'cart.dart';

// ============================================================================
//  Infratuzilma (main.dart da override qilinadi)
// ============================================================================

final databaseProvider = Provider<AppDatabase>((ref) => throw UnimplementedError('main.dart da override qiling'));
final notificationServiceProvider = Provider<NotificationService>((ref) => NotificationService());

// ============================================================================
//  Repository'lar
// ============================================================================

final settingsRepoProvider = Provider((ref) => SettingsRepository(ref.watch(databaseProvider)));

Future<String> Function() _deviceId(Ref ref) => () => ref.read(settingsRepoProvider).deviceId();

final productRepoProvider = Provider((ref) => ProductRepository(ref.watch(databaseProvider), _deviceId(ref)));
final stockRepoProvider = Provider((ref) => StockRepository(ref.watch(databaseProvider), _deviceId(ref)));
final userRepoProvider = Provider((ref) => UserRepository(ref.watch(databaseProvider), _deviceId(ref)));
final saleRepoProvider = Provider((ref) => SaleRepository(ref.watch(databaseProvider)));
final statsRepoProvider = Provider((ref) => StatsRepository(ref.watch(databaseProvider)));
final alertRepoProvider = Provider((ref) => AlertRepository(ref.watch(databaseProvider)));

// ============================================================================
//  Servislar
// ============================================================================

final alertServiceProvider = Provider((ref) {
  final s = AlertService(
    alerts: ref.watch(alertRepoProvider),
    products: ref.watch(productRepoProvider),
    sales: ref.watch(saleRepoProvider),
    settings: ref.watch(settingsRepoProvider),
    notifications: ref.watch(notificationServiceProvider),
  );
  ref.onDispose(s.dispose);
  return s;
});

final checkoutServiceProvider = Provider((ref) => CheckoutService(
      db: ref.watch(databaseProvider),
      settings: ref.watch(settingsRepoProvider),
      stock: ref.watch(stockRepoProvider),
      sales: ref.watch(saleRepoProvider),
      stats: ref.watch(statsRepoProvider),
      users: ref.watch(userRepoProvider),
      alerts: ref.watch(alertServiceProvider),
    ));

final printerServiceProvider = Provider((ref) => PrinterService(ref.watch(settingsRepoProvider)));

final syncServiceProvider = Provider((ref) {
  final s = SyncService(
    db: ref.watch(databaseProvider),
    settings: ref.watch(settingsRepoProvider),
    stock: ref.watch(stockRepoProvider),
    stats: ref.watch(statsRepoProvider),
    alerts: ref.watch(alertServiceProvider),
  );
  ref.onDispose(s.dispose);
  return s;
});

// ============================================================================
//  Sozlamalar va mavzu
// ============================================================================

final settingsProvider = StreamProvider<Map<String, String>>((ref) => ref.watch(settingsRepoProvider).watchAll());

String? _setting(Ref ref, String key) => ref.watch(settingsProvider).value?[key];

final themeModeProvider = Provider<ThemeMode>((ref) {
  switch (_setting(ref, SettingKeys.themeMode)) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
});

final frequentDaysProvider = Provider<int>((ref) => int.tryParse(_setting(ref, SettingKeys.frequentDays) ?? '') ?? 7);

final dailyTargetProvider = Provider<int>((ref) => int.tryParse(_setting(ref, SettingKeys.dailyTarget) ?? '') ?? 0);

// ============================================================================
//  Autentifikatsiya
// ============================================================================

class AuthNotifier extends Notifier<User?> {
  @override
  User? build() => null;

  Future<void> login(String username, String password) async {
    state = await ref.read(userRepoProvider).login(username, password);
  }

  void logout() {
    ref.read(cartProvider.notifier).clear();
    state = null;
  }

  bool get isAdmin => state != null && UserRole.fromCode(state!.role) == UserRole.admin;
}

final authProvider = NotifierProvider<AuthNotifier, User?>(AuthNotifier.new);

final currentRoleProvider = Provider<UserRole?>((ref) {
  final u = ref.watch(authProvider);
  return u == null ? null : UserRole.fromCode(u.role);
});

// ============================================================================
//  Savat
// ============================================================================

class CartNotifier extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  /// Tovar qo'shish: savatda bo'lsa — miqdor oshadi.
  void add(Product p, {double qty = 1}) {
    final lines = [...state.lines];
    final i = lines.indexWhere((l) => l.product.id == p.id);
    if (i >= 0) {
      lines[i] = lines[i].copyWith(qty: lines[i].qty + qty, product: p);
      // Oxirgi qo'shilgan qator ro'yxat boshida ko'rinadi.
      final line = lines.removeAt(i);
      lines.insert(0, line);
    } else {
      lines.insert(0, CartLine(product: p, qty: qty));
    }
    state = state.copyWith(lines: lines);
  }

  void setQty(String productId, double qty) {
    if (qty <= 0) {
      remove(productId);
      return;
    }
    state = state.copyWith(
      lines: [for (final l in state.lines) l.product.id == productId ? l.copyWith(qty: qty) : l],
    );
  }

  void increment(String productId, [double step = 1]) {
    final l = state.lines.firstWhere((x) => x.product.id == productId);
    setQty(productId, l.qty + step);
  }

  void decrement(String productId, [double step = 1]) {
    final l = state.lines.firstWhere((x) => x.product.id == productId);
    setQty(productId, l.qty - step);
  }

  void remove(String productId) {
    state = state.copyWith(lines: state.lines.where((l) => l.product.id != productId).toList());
    if (state.lines.isEmpty) clearDiscount();
  }

  void setDiscount(DiscountType type, double value, {User? approvedBy}) {
    state = state.copyWith(discountType: type, discountValue: value, discountApprovedBy: () => approvedBy);
  }

  void clearDiscount() =>
      state = state.copyWith(discountType: DiscountType.none, discountValue: 0, discountApprovedBy: () => null);

  void clear() => state = const CartState();
}

final cartProvider = NotifierProvider<CartNotifier, CartState>(CartNotifier.new);

// ============================================================================
//  Real-time ko'rsatkichlar
// ============================================================================

final todaySummaryProvider =
    StreamProvider<PeriodSummary>((ref) => ref.watch(statsRepoProvider).watchSummary(DayRange.today()));

final unreadAlertsProvider = StreamProvider<int>((ref) => ref.watch(alertRepoProvider).watchUnreadCount());

final frequentProductsProvider = StreamProvider<List<ProductSales>>((ref) {
  final days = ref.watch(frequentDaysProvider);
  return ref.watch(statsRepoProvider).watchFrequent(days: days);
});

/// Joriy mavsum (ilova ochiq qolsa ham har soatda qayta tekshiriladi).
final currentSeasonProvider = StreamProvider<Season>((ref) async* {
  yield Season.current;
  yield* Stream.periodic(const Duration(hours: 1), (_) => Season.current);
});

final seasonalRecsProvider = StreamProvider<List<ProductSales>>((ref) {
  final season = ref.watch(currentSeasonProvider).value ?? Season.current;
  return ref.watch(statsRepoProvider).watchSeasonal(season);
});

final categoriesProvider =
    StreamProvider<List<ProductCategory>>((ref) => ref.watch(productRepoProvider).watchCategories());

final lowStockProvider = StreamProvider<List<Product>>((ref) => ref.watch(productRepoProvider).watchLowStock());

final usersProvider = StreamProvider<List<User>>((ref) => ref.watch(userRepoProvider).watchAll());
