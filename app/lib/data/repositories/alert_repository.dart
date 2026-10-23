import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

class AlertRepository {
  AlertRepository(this.db);
  final AppDatabase db;

  /// Yangi alert yaratish. Agar shu `dedupeKey` bilan o'qilmagan alert
  /// allaqachon bo'lsa — qayta yaratilmaydi. Qaytaradi: yaratilgan alert yoki null.
  Future<Alert?> create({
    required AlertType type,
    required AlertSeverity severity,
    required String title,
    required String message,
    String? refId,
    String? dedupeKey,
  }) async {
    if (dedupeKey != null) {
      final existing = await (db.select(db.alerts)
            ..where((a) => a.dedupeKey.equals(dedupeKey) & a.isRead.equals(false))
            ..limit(1))
          .getSingleOrNull();
      if (existing != null) return null;
    }
    final alert = Alert(
      id: Ids.newId(),
      type: type.code,
      severity: severity.code,
      title: title,
      message: message,
      refId: refId,
      dedupeKey: dedupeKey,
      isRead: false,
      createdAt: Ids.nowMs(),
    );
    await db.into(db.alerts).insert(alert);
    return alert;
  }

  /// Berilgan kalit bilan alert umuman bo'lganmi (o'qilgan bo'lsa ham).
  Future<bool> existsKey(String dedupeKey) async {
    final row = await (db.select(db.alerts)
          ..where((a) => a.dedupeKey.equals(dedupeKey))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Stream<List<Alert>> watchAll({bool unreadOnly = false, int limit = 300}) {
    final q = db.select(db.alerts);
    if (unreadOnly) q.where((a) => a.isRead.equals(false));
    q
      ..orderBy([(a) => OrderingTerm.desc(a.createdAt)])
      ..limit(limit);
    return q.watch();
  }

  Stream<int> watchUnreadCount() {
    final c = db.alerts.id.count();
    return (db.selectOnly(db.alerts)
          ..addColumns([c])
          ..where(db.alerts.isRead.equals(false)))
        .map((r) => r.read(c) ?? 0)
        .watchSingle();
  }

  Future<void> markRead(String id) =>
      (db.update(db.alerts)..where((a) => a.id.equals(id))).write(const AlertsCompanion(isRead: Value(true)));

  Future<void> markAllRead() =>
      (db.update(db.alerts)..where((a) => a.isRead.equals(false))).write(const AlertsCompanion(isRead: Value(true)));

  /// Alertlarni o'chirish: [types] berilsa — faqat shu turlar, aks holda hammasi.
  Future<int> deleteAll({Iterable<String>? types}) {
    final q = db.delete(db.alerts);
    if (types != null) q.where((a) => a.type.isIn(types));
    return q.go();
  }

  Future<void> delete(String id) => (db.delete(db.alerts)..where((a) => a.id.equals(id))).go();

  /// Kam qoldiq muammosi hal bo'lganda tegishli alertlarni yopish.
  Future<void> resolveByKey(String dedupeKey) => (db.update(db.alerts)
        ..where((a) => a.dedupeKey.equals(dedupeKey) & a.isRead.equals(false)))
      .write(const AlertsCompanion(isRead: Value(true)));

  /// 90 kundan eski o'qilgan alertlarni tozalash.
  Future<int> purgeOld({int days = 90}) {
    final cutoff = Ids.nowMs() - days * 86400000;
    return (db.delete(db.alerts)..where((a) => a.isRead.equals(true) & a.createdAt.isSmallerThanValue(cutoff))).go();
  }
}
