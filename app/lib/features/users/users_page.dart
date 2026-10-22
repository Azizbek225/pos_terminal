import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/branch.dart';
import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/activity_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

final _auditProvider = StreamProvider<List<AuditEntry>>((ref) => ref.watch(userRepoProvider).watchAudit());

/// Xodimlar (foydalanuvchilar) va audit jurnali. Faqat Admin uchun.
class UsersPage extends ConsumerWidget {
  const UsersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.people_outline), text: 'Xodimlar'),
          Tab(icon: Icon(Icons.history), text: 'Audit jurnali'),
        ]),
        Expanded(
          child: TabBarView(children: [
            _UsersList(),
            _AuditList(),
          ]),
        ),
      ]),
    );
  }
}

class _UsersList extends ConsumerWidget {
  const _UsersList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider).value ?? const <User>[];
    final branches = ref.watch(branchesProvider).value ?? const <Branch>[];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showUserDialog(context, ref),
        icon: const Icon(Icons.person_add),
        label: const Text('Yangi xodim'),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Rollar'),
            subtitle: Text(
              "Admin — barcha bo'limlar, 20% dan yuqori chegirma, qaytarish, sozlamalar.\n"
              "Kassir — savdo, o'z cheklari tarixi, alertlar; chegirma 20% gacha.\n"
              'Omborchi — ombor (kirim, chiqim, inventarizatsiya), mavsumiy tahlil, alertlar.\n'
              "Filiallar: har bir xodimga qaysi filialda qaysi rol borligini alohida belgilash mumkin.",
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final u in users)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: CircleAvatar(child: Text(u.fullName.isEmpty ? '?' : u.fullName[0].toUpperCase())),
              title: Text('${u.fullName}${u.isActive ? '' : ' (bloklangan)'}'),
              subtitle: Text('${u.username} · ${_accessText(u, branches)}'
                  '${u.lastLoginAt == null ? '' : ' · oxirgi kirish: ${Fmt.dateTimeMs(u.lastLoginAt!)}'}'),
              onTap: () => showUserDialog(context, ref, user: u),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (u.id == ref.read(authProvider)?.id) {
                    showMessage(context, "O'zingizni o'chira olmaysiz", error: true);
                    return;
                  }
                  if (await confirmDialog(context, "Xodimni o'chirish", '${u.fullName} o\'chirilsinmi?',
                      danger: true, ok: "O'chirish")) {
                    try {
                      await ref.read(userRepoProvider).delete(u.id);
                    } catch (e) {
                      if (context.mounted) showMessage(context, e.toString(), error: true);
                    }
                  }
                },
              ),
            ),
          ),
      ]),
    );
  }
}

String _accessText(User u, List<Branch> branches) {
  final map = u.branchRoleMap;
  if (map.isEmpty) {
    final r = UserRole.fromCode(u.role).label;
    return branches.length > 1 ? '$r (barcha filiallar)' : r;
  }
  final names = {for (final b in branches) b.id: b.name};
  return map.entries.map((e) => '${names[e.key] ?? '?'}: ${UserRole.fromCode(e.value).label}').join(', ');
}

class _AuditList extends ConsumerWidget {
  const _AuditList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_auditProvider).value ?? const <AuditEntry>[];
    if (list.isEmpty) return const EmptyState(icon: Icons.history, text: "Jurnal bo'sh");
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = list[i];
        return ListTile(
          dense: true,
          title: Text('${kActivityLabels[a.action] ?? a.action} — ${a.userName}'),
          subtitle: a.details.isEmpty ? null : Text(a.details),
          trailing: Text(Fmt.dateTimeMs(a.createdAt)),
        );
      },
    );
  }
}

/// Xodim qo'shish / tahrirlash dialogi.
Future<void> showUserDialog(BuildContext context, WidgetRef ref, {User? user}) async {
  final name = TextEditingController(text: user?.fullName ?? '');
  final login = TextEditingController(text: user?.username ?? '');
  final phone = TextEditingController(text: user?.phone ?? '');
  final pass = TextEditingController();
  var role = user == null ? UserRole.cashier : UserRole.fromCode(user.role);
  var active = user?.isActive ?? true;
  final branches = (ref.read(branchesProvider).value ?? const <Branch>[]).where((b) => b.isActive).toList();
  final branchRoles = <String, String>{...?user?.branchRoleMap};
  var allBranches = branchRoles.isEmpty;
  String? error;

  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(user == null ? 'Yangi xodim' : 'Xodimni tahrirlash'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'F.I.Sh. *')),
              const SizedBox(height: 10),
              TextField(controller: login, decoration: const InputDecoration(labelText: 'Login *')),
              const SizedBox(height: 10),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Telefon')),
              const SizedBox(height: 10),
              DropdownButtonFormField<UserRole>(
                isExpanded: true,
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: [for (final r in UserRole.values) DropdownMenuItem(value: r, child: Text(r.label))],
                onChanged: (v) => setState(() => role = v ?? role),
              ),
              if (branches.length > 1) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: allBranches,
                  onChanged: (v) => setState(() {
                    allBranches = v;
                    if (!v && branchRoles.isEmpty) {
                      branchRoles[ref.read(currentBranchProvider)] = role.code;
                    }
                  }),
                  title: const Text('Barcha filiallarda shu rol'),
                  subtitle: const Text("O'chirsangiz — har bir filial uchun alohida ruxsat"),
                ),
                if (!allBranches)
                  for (final b in branches)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: branchRoles[b.id] ?? '',
                        decoration: InputDecoration(labelText: b.name, prefixIcon: const Icon(Icons.store_outlined)),
                        items: [
                          const DropdownMenuItem(value: '', child: Text("Ruxsat yo'q")),
                          for (final r in UserRole.values) DropdownMenuItem(value: r.code, child: Text(r.label)),
                        ],
                        onChanged: (v) => setState(() {
                          if (v == null || v.isEmpty) {
                            branchRoles.remove(b.id);
                          } else {
                            branchRoles[b.id] = v;
                          }
                        }),
                      ),
                    ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: pass,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: user == null ? 'Parol *' : "Yangi parol (o'zgartirmaslik uchun bo'sh qoldiring)",
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: active,
                onChanged: (v) => setState(() => active = v),
                title: const Text('Faol'),
              ),
              if (error != null) Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Bekor qilish')),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) {
                setState(() => error = 'F.I.Sh. kiriting');
                return;
              }
              if (!allBranches && branchRoles.isEmpty) {
                setState(() => error = 'Kamida bitta filialga ruxsat bering');
                return;
              }
              try {
                await ref.read(userRepoProvider).save(
                      id: user?.id,
                      username: login.text,
                      fullName: name.text,
                      role: role,
                      password: pass.text.isEmpty ? null : pass.text,
                      phone: phone.text.trim().isEmpty ? null : phone.text.trim(),
                      isActive: active,
                      branchRoles: allBranches ? const {} : branchRoles,
                    );
                ref.read(syncServiceProvider).requestSync();
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                setState(() => error = e.toString());
              }
            },
            child: const Text('Saqlash'),
          ),
        ],
      ),
    ),
  );
  for (final x in [name, login, phone, pass]) {
    x.dispose();
  }
}

/// Har qanday foydalanuvchi o'z parolini o'zgartirishi.
Future<void> showChangeOwnPasswordDialog(BuildContext context, WidgetRef ref, User user) async {
  final oldP = TextEditingController();
  final newP = TextEditingController();
  final newP2 = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text("Parolni o'zgartirish"),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: oldP, obscureText: true, decoration: const InputDecoration(labelText: 'Joriy parol')),
            const SizedBox(height: 10),
            TextField(controller: newP, obscureText: true, decoration: const InputDecoration(labelText: 'Yangi parol')),
            const SizedBox(height: 10),
            TextField(controller: newP2, obscureText: true, decoration: const InputDecoration(labelText: 'Yangi parolni takrorlang')),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Bekor qilish')),
          FilledButton(
            onPressed: () async {
              if (newP.text != newP2.text) {
                setState(() => error = 'Yangi parollar mos emas');
                return;
              }
              try {
                final repo = ref.read(userRepoProvider);
                final fresh = await repo.login(user.username, oldP.text);
                await repo.save(
                  id: fresh.id,
                  username: fresh.username,
                  fullName: fresh.fullName,
                  role: UserRole.fromCode(fresh.role),
                  password: newP.text,
                  phone: fresh.phone,
                  isActive: fresh.isActive,
                );
                ref.read(syncServiceProvider).requestSync();
                if (c.mounted) {
                  Navigator.pop(c);
                  showMessage(context, "Parol o'zgartirildi");
                }
              } catch (e) {
                setState(() => error = e.toString());
              }
            },
            child: const Text('Saqlash'),
          ),
        ],
      ),
    ),
  );
  for (final x in [oldP, newP, newP2]) {
    x.dispose();
  }
}
