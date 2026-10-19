import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

/// Filiallar ro'yxati (barcha qurilmalarga sinxronlanadi).
class BranchRepository {
  BranchRepository(this.db, this.deviceId);
  final AppDatabase db;
  final Future<String> Function() deviceId;

  Stream<List<Branch>> watchAll() => (db.select(db.branches)
        ..where((b) => b.isDeleted.equals(false))
        ..orderBy([(b) => OrderingTerm(expression: b.sortOrder), (b) => OrderingTerm(expression: b.name)]))
      .watch();

  Future<List<Branch>> all() => (db.select(db.branches)
        ..where((b) => b.isDeleted.equals(false))
        ..orderBy([(b) => OrderingTerm(expression: b.sortOrder), (b) => OrderingTerm(expression: b.name)]))
      .get();

  Future<Branch?> byId(String id) => (db.select(db.branches)..where((b) => b.id.equals(id))).getSingleOrNull();

  Future<String> save({String? id, required String name, String address = '', String phone = '', bool isActive = true}) async {
    final n = name.trim();
    if (n.isEmpty) throw Exception('Filial nomini kiriting');
    final now = Ids.nowMs();
    final dev = await deviceId();
    if (id == null) {
      final count = (await all()).length;
      final newId = Ids.newId();
      await db.into(db.branches).insert(BranchesCompanion.insert(
            id: newId,
            name: n,
            address: Value(address.trim()),
            phone: Value(phone.trim()),
            isActive: Value(isActive),
            sortOrder: Value(count),
            createdAt: now,
            updatedAt: now,
            deviceId: Value(dev),
          ));
      return newId;
    }
    final old = await byId(id);
    if (old == null) throw Exception('Filial topilmadi');
    if (!isActive && id == kDefaultBranchId) throw Exception("Asosiy filialni o'chirib bo'lmaydi");
    await (db.update(db.branches)..where((b) => b.id.equals(id))).write(BranchesCompanion(
      name: Value(n),
      address: Value(address.trim()),
      phone: Value(phone.trim()),
      isActive: Value(isActive),
      updatedAt: Value(now),
      version: Value(old.version + 1),
      deviceId: Value(dev),
      dirty: const Value(true),
    ));
    return id;
  }

  /// Yumshoq o'chirish. Savdo va harakatlar tarixi saqlanib qoladi.
  Future<void> delete(String id) async {
    if (id == kDefaultBranchId) throw Exception("Asosiy filialni o'chirib bo'lmaydi");
    final old = await byId(id);
    if (old == null) return;
    await (db.update(db.branches)..where((b) => b.id.equals(id))).write(BranchesCompanion(
      isDeleted: const Value(true),
      isActive: const Value(false),
      updatedAt: Value(Ids.nowMs()),
      version: Value(old.version + 1),
      deviceId: Value(await deviceId()),
      dirty: const Value(true),
    ));
  }
}
