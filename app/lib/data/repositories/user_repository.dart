import 'package:drift/drift.dart';

import '../../core/constants.dart';
import '../../core/security.dart';
import '../database.dart';

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Foydalanuvchilar va audit jurnali.
class UserRepository {
  UserRepository(this.db, this.deviceId);
  final AppDatabase db;
  final Future<String> Function() deviceId;

  /// Login. Muvaffaqiyatsiz bo'lsa [AuthException].
  Future<User> login(String username, String password) async {
    final u = await (db.select(db.users)
          ..where((t) => t.username.equals(username.trim().toLowerCase()) & t.isDeleted.equals(false)))
        .getSingleOrNull();
    if (u == null || !PasswordHasher.verify(password, u.salt, u.passwordHash)) {
      throw AuthException("Login yoki parol noto'g'ri");
    }
    if (!u.isActive) throw AuthException('Foydalanuvchi bloklangan');
    await (db.update(db.users)..where((t) => t.id.equals(u.id)))
        .write(UsersCompanion(lastLoginAt: Value(Ids.nowMs())));
    await log(u, 'login', '');
    return u;
  }

  /// Admin huquqini tasdiqlash (masalan, 20% dan yuqori chegirma uchun).
  Future<User> verifyAdmin(String username, String password) async {
    final u = await login(username, password);
    if (UserRole.fromCode(u.role) != UserRole.admin) {
      throw AuthException('Bu amal uchun Admin huquqi kerak');
    }
    return u;
  }

  Stream<List<User>> watchAll() => (db.select(db.users)
        ..where((t) => t.isDeleted.equals(false))
        ..orderBy([(t) => OrderingTerm(expression: t.fullName)]))
      .watch();

  Future<List<User>> all() =>
      (db.select(db.users)..where((t) => t.isDeleted.equals(false))).get();

  Future<User?> byId(String id) => (db.select(db.users)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> save({
    String? id,
    required String username,
    required String fullName,
    required UserRole role,
    String? password,
    String? phone,
    bool isActive = true,
  }) async {
    final uname = username.trim().toLowerCase();
    if (uname.length < 3) throw AuthException("Login kamida 3 ta belgidan iborat bo'lsin");
    final dup = await (db.select(db.users)
          ..where((t) => t.username.equals(uname) & t.isDeleted.equals(false)))
        .getSingleOrNull();
    if (dup != null && dup.id != id) throw AuthException('Bu login band');

    final now = Ids.nowMs();
    final dev = await deviceId();
    if (id == null) {
      if (password == null || password.length < 4) {
        throw AuthException("Parol kamida 4 ta belgidan iborat bo'lsin");
      }
      final salt = PasswordHasher.newSalt();
      await db.into(db.users).insert(UsersCompanion.insert(
            id: Ids.newId(),
            username: uname,
            fullName: fullName.trim(),
            role: role.code,
            passwordHash: PasswordHasher.hash(password, salt),
            salt: salt,
            phone: Value(phone),
            isActive: Value(isActive),
            createdAt: now,
            updatedAt: now,
            deviceId: Value(dev),
          ));
      return;
    }
    final existing = await byId(id);
    if (existing == null) throw AuthException('Foydalanuvchi topilmadi');
    var comp = UsersCompanion(
      username: Value(uname),
      fullName: Value(fullName.trim()),
      role: Value(role.code),
      phone: Value(phone),
      isActive: Value(isActive),
      updatedAt: Value(now),
      version: Value(existing.version + 1),
      deviceId: Value(dev),
      dirty: const Value(true),
    );
    if (password != null && password.isNotEmpty) {
      if (password.length < 4) throw AuthException("Parol kamida 4 ta belgidan iborat bo'lsin");
      final salt = PasswordHasher.newSalt();
      comp = comp.copyWith(passwordHash: Value(PasswordHasher.hash(password, salt)), salt: Value(salt));
    }
    await (db.update(db.users)..where((t) => t.id.equals(id))).write(comp);
  }

  /// Oxirgi faol Admin o'chirilishiga yo'l qo'ymaslik.
  Future<void> delete(String id) async {
    final u = await byId(id);
    if (u == null) return;
    if (u.role == UserRole.admin.code) {
      final admins = (await all()).where((x) => x.role == UserRole.admin.code && x.isActive).length;
      if (admins <= 1) throw AuthException("Oxirgi Adminni o'chirib bo'lmaydi");
    }
    await (db.update(db.users)..where((t) => t.id.equals(id))).write(UsersCompanion(
      isDeleted: const Value(true),
      isActive: const Value(false),
      updatedAt: Value(Ids.nowMs()),
      version: Value(u.version + 1),
      dirty: const Value(true),
    ));
  }

  /// Audit jurnaliga yozish.
  Future<void> log(User user, String action, String details) async {
    final now = Ids.nowMs();
    await db.into(db.auditLog).insert(AuditLogCompanion.insert(
          id: Ids.newId(),
          userId: user.id,
          userName: user.fullName,
          action: action,
          details: Value(details),
          createdAt: now,
          updatedAt: now,
          deviceId: Value(await deviceId()),
        ));
  }

  Stream<List<AuditEntry>> watchAudit({int limit = 200}) => (db.select(db.auditLog)
        ..orderBy([(a) => OrderingTerm.desc(a.createdAt)])
        ..limit(limit))
      .watch();
}
