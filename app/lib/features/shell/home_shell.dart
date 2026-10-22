import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'common_widgets.dart';
import '../../core/constants.dart';
import '../../data/database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../state/providers.dart';
import '../activity/activity_page.dart';
import '../alerts/alerts_page.dart';
import '../monitoring/monitoring_page.dart';
import '../dashboard/dashboard_page.dart';
import '../history/history_page.dart';
import '../inventory/inventory_page.dart';
import '../pos/pos_page.dart';
import '../seasonal/seasonal_page.dart';
import '../settings/settings_page.dart';
import '../suppliers/debts_page.dart';
import '../users/users_page.dart';
import 'top_panel.dart';

/// Navigatsiya bo'limi.
class _Dest {
  const _Dest(this.label, this.icon, this.builder, this.roles, {this.ownerOnly = false});
  final String label;
  final IconData icon;
  final Widget Function() builder;
  final Set<UserRole> roles;

  /// Faqat bosh admin (barcha filiallarda Admin).
  final bool ownerOnly;
}

final _destinations = <_Dest>[
  _Dest('Savdo', Icons.point_of_sale, () => const PosPage(), {UserRole.admin, UserRole.cashier}),
  _Dest('Monitoring', Icons.monitor_heart_outlined, () => const MonitoringPage(), {UserRole.admin}),
  _Dest('Dashboard', Icons.dashboard_outlined, () => const DashboardPage(), {UserRole.admin}),
  _Dest('Ombor', Icons.inventory_2_outlined, () => const InventoryPage(), {UserRole.admin, UserRole.storekeeper}),
  _Dest('Tarix', Icons.receipt_long_outlined, () => const HistoryPage(), {UserRole.admin, UserRole.cashier}),
  _Dest('Qarzlar', Icons.account_balance_wallet_outlined, () => const DebtsPage(),
      {UserRole.admin, UserRole.storekeeper}),
  _Dest("O'zgarishlar", Icons.manage_history, () => const ActivityPage(), {UserRole.admin, UserRole.storekeeper}),
  _Dest('Mavsumiy', Icons.eco_outlined, () => const SeasonalPage(), {UserRole.admin, UserRole.storekeeper}),
  _Dest('Alertlar', Icons.notifications_outlined, () => const AlertsPage(),
      {UserRole.admin, UserRole.cashier, UserRole.storekeeper}),
  _Dest('Xodimlar', Icons.people_outline, () => const UsersPage(), {UserRole.admin}, ownerOnly: true),
  _Dest('Sozlamalar', Icons.settings_outlined, () => const SettingsPage(), {UserRole.admin}),
];

/// Bo'limni boshqa joydan ochish uchun (masalan, yuqori paneldagi alert tugmasi).
class ShellNavigator extends Notifier<String> {
  @override
  String build() => '';
  void open(String label) => state = label;
}

final shellNavProvider = NotifierProvider<ShellNavigator, String>(ShellNavigator.new);

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  StreamSubscription<Alert>? _alertSub;

  @override
  void initState() {
    super.initState();
    // Xodim ruxsatlari boshqa qurilmada o'zgarsa (sinxronlash) — shu yerda ham.
    ref.listenManual(usersProvider, (_, next) {
      final list = next.value;
      if (list != null) ref.read(authProvider.notifier).refresh(list);
    });
    // Yangi alertlarni darhol ekranda ko'rsatish.
    _alertSub = ref.read(alertServiceProvider).onNewAlert.listen((a) {
      if (!mounted) return;
      final critical = a.severity == AlertSeverity.critical.code;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: critical ? Theme.of(context).colorScheme.error : null,
        content: Text('${a.title}: ${a.message}'),
        margin: snackMargin(context),
        action: SnackBarAction(label: "Ko'rish", onPressed: () => ref.read(shellNavProvider.notifier).open('Alertlar')),
      ));
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentRoleProvider);
    final owner = ref.watch(isOwnerProvider);
    final branch = ref.watch(currentBranchProvider);
    if (role == null) return const _NoAccessPage();
    final dests = _destinations.where((d) => d.roles.contains(role) && (!d.ownerOnly || owner)).toList();
    if (_index >= dests.length) _index = 0;

    ref.listen(shellNavProvider, (_, label) {
      final i = dests.indexWhere((d) => d.label == label);
      if (i >= 0) setState(() => _index = i);
    });

    final wide = MediaQuery.sizeOf(context).width >= 900;
    // Filial almashsa sahifa noldan quriladi (eski filial ma'lumoti qolmasligi uchun).
    final page = KeyedSubtree(key: ValueKey('${dests[_index].label}@$branch'), child: dests[_index].builder());

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _index = i),
              leading: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Icon(Icons.storefront, size: 32, color: Theme.of(context).colorScheme.primary),
              ),
              destinations: [
                for (final d in dests)
                  NavigationRailDestination(
                    icon: d.label == 'Alertlar' ? _AlertBadge(icon: d.icon) : Icon(d.icon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(children: [
                const TopPanel(),
                Expanded(child: page),
              ]),
            ),
          ],
        ),
      );
    }

    // Telefon: yuqorida ixcham panel, pastda navigatsiya (5 tadan ko'p bo'lsa — menyu).
    final primary = dests.take(4).toList();
    final more = dests.skip(4).toList();
    final selectedInPrimary = _index < primary.length;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 0,
      ),
      body: Column(children: [
        const TopPanel(compact: true),
        Expanded(child: page),
      ]),
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: selectedInPrimary ? _index : primary.length,
        onDestinationSelected: (i) async {
          if (i < primary.length) {
            setState(() => _index = i);
            return;
          }
          final picked = await showModalBottomSheet<int>(
            context: context,
            builder: (c) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (var j = 0; j < more.length; j++)
                  ListTile(
                    leading: Icon(more[j].icon),
                    title: Text(more[j].label),
                    onTap: () => Navigator.pop(c, primary.length + j),
                  ),
              ]),
            ),
          );
          if (picked != null) setState(() => _index = picked);
        },
        destinations: [
          for (final d in primary) NavigationDestination(icon: Icon(d.icon), label: d.label),
          if (more.isNotEmpty)
            NavigationDestination(
              icon: const _AlertBadge(icon: Icons.more_horiz),
              label: selectedInPrimary ? 'Yana' : dests[_index].label,
            ),
        ],
      ),
    );
  }
}

/// Xodimga joriy filialda ruxsat yo'q (masalan, ruxsati boshqa qurilmada olib tashlandi).
class _NoAccessPage extends ConsumerWidget {
  const _NoAccessPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(accessibleBranchesProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 12),
              Text("Bu filialda sizga ruxsat yo'q", textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              for (final b in branches)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.store_outlined),
                    title: Text(b.name),
                    onTap: () => ref.read(currentBranchProvider.notifier).select(b.id),
                  ),
                ),
              TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Chiqish')),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AlertBadge extends ConsumerWidget {
  const _AlertBadge({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unreadAlertsProvider).value ?? 0;
    return Badge(isLabelVisible: n > 0, label: Text('$n'), child: Icon(icon));
  }
}

/// Mavzuni almashtirish (yuqori paneldan).
Future<void> toggleTheme(WidgetRef ref, Brightness current) async {
  await ref
      .read(settingsRepoProvider)
      .set(SettingKeys.themeMode, current == Brightness.dark ? 'light' : 'dark');
}
