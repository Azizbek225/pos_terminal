import 'dart:async';

import '../core/constants.dart';
import '../core/formatters.dart';
import '../data/database.dart';
import '../data/repositories/alert_repository.dart';
import '../data/repositories/product_repository.dart';
import '../data/repositories/sale_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'notification_service.dart';

/// Alert qoidalari:
/// 1. Kam qoldiq — `stockQty <= minStock` (minStock > 0 bo'lsa).
/// 2. Tovar tugadi — `stockQty <= 0`.
/// 3. Kunlik maqsad — belgilangan soatdan keyin bugungi savdo maqsaddan past.
/// 4. Anomal chek — summa absolyut chegaradan yoki o'rtacha chekdan N barobar katta.
class AlertService {
  AlertService({
    required this.alerts,
    required this.products,
    required this.sales,
    required this.settings,
    required this.notifications,
  });

  final AlertRepository alerts;
  final ProductRepository products;
  final SaleRepository sales;
  final SettingsRepository settings;
  final NotificationService notifications;

  /// Yangi alertlar oqimi — UI ularni darhol SnackBar sifatida ko'rsatadi.
  final _newAlerts = StreamController<Alert>.broadcast();
  Stream<Alert> get onNewAlert => _newAlerts.stream;

  Timer? _timer;

  /// Davriy tekshiruvlarni ishga tushirish (kunlik maqsad).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => checkDailyTarget());
    Future<void>.delayed(const Duration(seconds: 5), checkDailyTarget);
    Future<void>.delayed(const Duration(seconds: 3), checkAllStock);
    Future<void>.delayed(const Duration(seconds: 10), alerts.purgeOld);
  }

  void dispose() {
    _timer?.cancel();
    _newAlerts.close();
  }

  Future<void> _emit(Alert? a) async {
    if (a == null) return;
    _newAlerts.add(a);
    await notifications.show(a.title, a.message, critical: a.severity == AlertSeverity.critical.code);
  }

  /// Barcha tovarlar qoldig'ini tekshirish (ilova ochilganda).
  Future<void> checkAllStock() async {
    try {
      final rows = await products.db.customSelect('SELECT id FROM products WHERE is_deleted = 0 AND min_stock > 0').get();
      await checkStock(rows.map((r) => r.read<String>('id')));
    } catch (_) {}
  }

  Future<void> checkStock(Iterable<String> productIds) async {
    // Sozlamalarda o'chirilgan bo'lsa — kam qolgan / tugagan tovar haqida xabar yo'q.
    if (await settings.get(SettingKeys.stockAlerts) == '0') return;
    final list = await products.byIds(productIds.toSet());
    for (final p in list) {
      if (p.isDeleted || !p.isActive) continue;
      final lowKey = 'low:${p.id}';
      final outKey = 'out:${p.id}';
      if (p.stockQty <= 0 && p.minStock > 0) {
        await _emit(await alerts.create(
          type: AlertType.outOfStock,
          severity: AlertSeverity.critical,
          title: 'Tovar tugadi',
          message: '${p.name} — qoldiq: ${Fmt.qty(p.stockQty)} ${p.unit}',
          refId: p.id,
          dedupeKey: outKey,
        ));
      } else if (p.minStock > 0 && p.stockQty <= p.minStock) {
        await _emit(await alerts.create(
          type: AlertType.lowStock,
          severity: AlertSeverity.warning,
          title: 'Kam qoldiq',
          message: '${p.name} — qoldiq: ${Fmt.qty(p.stockQty)} ${p.unit} (min: ${Fmt.qty(p.minStock)})',
          refId: p.id,
          dedupeKey: lowKey,
        ));
      } else {
        // Qoldiq tiklandi — eski ogohlantirishlarni yopamiz.
        await alerts.resolveByKey(lowKey);
        await alerts.resolveByKey(outKey);
      }
    }
  }

  Future<void> checkAnomaly(Sale sale) async {
    final threshold = await settings.getInt(SettingKeys.anomalyThreshold, 5000000);
    final multiplier = double.tryParse(await settings.get(SettingKeys.anomalyMultiplier) ?? '') ?? 5;
    final avg = await sales.averageCheck();
    final overAbs = threshold > 0 && sale.total >= threshold;
    final overAvg = avg > 0 && sale.total >= avg * multiplier;
    if (overAbs || overAvg) {
      final reason = overAbs
          ? 'chegara ${Fmt.money(threshold)} dan katta'
          : "o'rtacha chekdan ${(sale.total / avg).toStringAsFixed(1)} barobar katta";
      await _emit(await alerts.create(
        type: AlertType.anomaly,
        severity: AlertSeverity.warning,
        title: 'Juda katta chek',
        message: '${sale.receiptNo}: ${Fmt.money(sale.total)} — $reason. Kassir: ${sale.cashierName}',
        refId: sale.id,
        dedupeKey: 'anomaly:${sale.id}',
      ));
    }
    // Katta chegirma ham anomaliya sifatida qayd etiladi.
    if (sale.subtotal > 0 && sale.discountAmount * 100 / sale.subtotal > kCashierMaxDiscountPercent) {
      await _emit(await alerts.create(
        type: AlertType.anomaly,
        severity: AlertSeverity.info,
        title: 'Katta chegirma',
        message: '${sale.receiptNo}: chegirma ${Fmt.money(sale.discountAmount)} '
            '(${(sale.discountAmount * 100 / sale.subtotal).toStringAsFixed(1)}%)',
        refId: sale.id,
        dedupeKey: 'discount:${sale.id}',
      ));
    }
  }

  Future<void> checkDailyTarget() async {
    try {
      final target = await settings.getInt(SettingKeys.dailyTarget, 0);
      if (target <= 0) return;
      final hour = await settings.getInt(SettingKeys.targetCheckHour, 18);
      final now = DateTime.now();
      if (now.hour < hour) return;
      final key = 'target:${now.year}-${now.month}-${now.day}';
      if (await alerts.existsKey(key)) return;
      final r = DayRange.today();
      final rows = await sales.db.customSelect(
        "SELECT COALESCE(SUM(total),0) t FROM sales WHERE status='completed' AND is_deleted=0 "
        'AND created_at >= ${r.fromMs} AND created_at < ${r.toMs}',
      ).getSingle();
      final today = rows.read<int>('t');
      if (today < target) {
        final pct = (today * 100 / target).toStringAsFixed(0);
        await _emit(await alerts.create(
          type: AlertType.dailyTarget,
          severity: AlertSeverity.warning,
          title: 'Kunlik maqsadga yetilmadi',
          message: 'Bugungi savdo ${Fmt.money(today)} — maqsadning $pct% i (${Fmt.money(target)})',
          dedupeKey: key,
        ));
      }
    } catch (_) {}
  }

  /// Sinxronlash/tizim xabarlari uchun umumiy alert.
  Future<void> system(String title, String message,
      {AlertType type = AlertType.system, AlertSeverity severity = AlertSeverity.info, String? dedupeKey}) async {
    await _emit(await alerts.create(
        type: type, severity: severity, title: title, message: message, dedupeKey: dedupeKey));
  }
}
