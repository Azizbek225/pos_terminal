import 'dart:async';
import 'dart:convert';

import '../data/database.dart';
import 'constants.dart';

/// Qurilmaning joriy filiali. Repository'lar savdo, qoldiq va jurnal
/// so'rovlarini shu filial bo'yicha bajaradi; filial almashsa, `watch*`
/// oqimlari ([watchInBranch]) avtomatik qayta ishga tushadi.
class BranchContext {
  BranchContext([String id = kDefaultBranchId]) : _id = id;

  String _id;
  final _changes = StreamController<String>.broadcast(sync: true);

  String get id => _id;
  Stream<String> get changes => _changes.stream;

  void set(String id) {
    if (id == _id) return;
    _id = id;
    _changes.add(id);
  }
}

/// Filialga bog'liq oqim: filial almashganda eski so'rov bekor qilinib,
/// yangi filial uchun qayta quriladi.
Stream<T> watchInBranch<T>(BranchContext ctx, Stream<T> Function(String branchId) build) {
  late final StreamController<T> c;
  StreamSubscription<T>? inner;
  StreamSubscription<String>? outer;
  void subscribe(String id) {
    inner?.cancel();
    inner = build(id).listen(c.add, onError: c.addError);
  }

  c = StreamController<T>(
    onListen: () {
      subscribe(ctx.id);
      outer = ctx.changes.listen(subscribe);
    },
    onPause: () => inner?.pause(),
    onResume: () => inner?.resume(),
    onCancel: () async {
      await outer?.cancel();
      await inner?.cancel();
    },
  );
  return c.stream;
}

/// Xodimning filiallardagi ruxsatlari.
extension UserBranchAccess on User {
  /// `{filial_id: rol_kodi}`. Bo'sh — asosiy rol barcha filiallarda.
  Map<String, String> get branchRoleMap => parseBranchRoles(branchRoles);

  /// Bosh admin: barcha filiallarda Admin (filiallar va xodimlarni boshqaradi).
  bool get isOwner => role == UserRole.admin.code && branchRoleMap.isEmpty;

  /// Shu filialdagi roli; ruxsat bo'lmasa null.
  UserRole? roleIn(String branchId) {
    final map = branchRoleMap;
    if (map.isEmpty) return UserRole.fromCode(role);
    final code = map[branchId];
    return code == null ? null : UserRole.fromCode(code);
  }

  bool canAccess(String branchId) => roleIn(branchId) != null;
}

Map<String, String> parseBranchRoles(String raw) {
  if (raw.trim().isEmpty) return const {};
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return {for (final e in m.entries) if (e.value is String) e.key: e.value as String};
  } catch (_) {
    return const {};
  }
}

String encodeBranchRoles(Map<String, String> roles) => roles.isEmpty ? '' : jsonEncode(roles);
