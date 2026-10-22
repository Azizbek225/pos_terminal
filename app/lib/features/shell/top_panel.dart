import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../services/sync/sync_service.dart';
import '../../state/providers.dart';
import '../users/users_page.dart';
import 'home_shell.dart';

/// Yuqori panel: bugungi savdo, o'rtacha chek, alertlar soni, sinxronlash holati,
/// mavzu va foydalanuvchi menyusi. Barcha qiymatlar real-time.
class TopPanel extends ConsumerWidget {
  const TopPanel({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = ref.watch(todaySummaryProvider).value;
    final alerts = ref.watch(unreadAlertsProvider).value ?? 0;
    final target = ref.watch(dailyTargetProvider);
    final user = ref.watch(authProvider);
    final role = ref.watch(currentRoleProvider);

    final total = summary?.total ?? 0;
    final progress = target > 0 ? (total / target).clamp(0.0, 1.0) : null;

    final items = <Widget>[
      _Metric(
        icon: Icons.payments_outlined,
        label: 'Bugungi savdo',
        value: Fmt.money(total),
        color: theme.colorScheme.primary,
        progress: progress,
      ),
      _Metric(
        icon: Icons.receipt_outlined,
        label: 'Cheklar',
        value: '${summary?.count ?? 0}',
        color: Colors.indigo,
      ),
      _Metric(
        icon: Icons.analytics_outlined,
        label: "O'rtacha chek",
        value: Fmt.money(summary?.average ?? 0),
        color: Colors.teal,
      ),
      InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => ref.read(shellNavProvider.notifier).open('Alertlar'),
        child: _Metric(
          icon: Icons.notifications_active_outlined,
          label: 'Alertlar',
          value: '$alerts',
          color: alerts > 0 ? theme.colorScheme.error : Colors.grey,
        ),
      ),
    ];

    return Material(
      color: theme.colorScheme.surface,
      elevation: 1,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: compact ? 4 : 8),
          child: Row(
            children: [
              _BranchSelector(compact: compact),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final w in items) Padding(padding: const EdgeInsets.only(right: 8), child: w),
                  ]),
                ),
              ),
              const _SyncIndicator(),
              IconButton(
                tooltip: "Yorug'/qorong'u rejim",
                icon: Icon(theme.brightness == Brightness.dark ? Icons.light_mode : Icons.dark_mode),
                onPressed: () => toggleTheme(ref, theme.brightness),
              ),
              PopupMenuButton<String>(
                tooltip: 'Foydalanuvchi',
                onSelected: (v) {
                  if (v == 'logout') ref.read(authProvider.notifier).logout();
                  if (v == 'password' && user != null) showChangeOwnPasswordDialog(context, ref, user);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Text('${user?.fullName ?? ''} — ${role?.label ?? ''}'),
                  ),
                  const PopupMenuItem(value: 'password', child: Text("Parolni o'zgartirish")),
                  const PopupMenuItem(value: 'logout', child: Text('Chiqish')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: CircleAvatar(
                    radius: 18,
                    child: Text((user?.fullName.isNotEmpty ?? false) ? user!.fullName[0].toUpperCase() : '?'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Joriy filial va uni almashtirish (filial bittadan ko'p bo'lsa).
class _BranchSelector extends ConsumerWidget {
  const _BranchSelector({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(branchesProvider).value ?? const [];
    if (all.where((b) => b.isActive).length < 2) return const SizedBox.shrink();
    final branches = ref.watch(accessibleBranchesProvider);
    final current = ref.watch(currentBranchProvider);
    final name = ref.watch(currentBranchNameProvider);
    final theme = Theme.of(context);
    final chip = Container(
      constraints: BoxConstraints(maxWidth: compact ? 130 : 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.store, size: 20, color: theme.colorScheme.onPrimaryContainer),
        const SizedBox(width: 6),
        Flexible(
          child: Text(name, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer)),
        ),
        if (branches.length > 1) Icon(Icons.arrow_drop_down, color: theme.colorScheme.onPrimaryContainer),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: branches.length < 2
          ? Tooltip(message: 'Filial', child: chip)
          : PopupMenuButton<String>(
              tooltip: 'Filialni tanlash',
              onSelected: (id) => ref.read(currentBranchProvider.notifier).select(id),
              itemBuilder: (_) => [
                for (final b in branches)
                  CheckedPopupMenuItem(value: b.id, checked: b.id == current, child: Text(b.name)),
              ],
              child: chip,
            ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value, required this.color, this.progress});
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          if (progress != null)
            SizedBox(
              width: 110,
              child: Tooltip(
                message: 'Kunlik maqsad: ${(progress! * 100).toStringAsFixed(0)}%',
                child: LinearProgressIndicator(value: progress, minHeight: 3, color: color),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(syncServiceProvider);
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: service.status,
      builder: (context, s, _) {
        final (icon, color, text) = switch (s.state) {
          SyncState.disabled => (Icons.cloud_off_outlined, Colors.grey, "Faqat lokal rejim (sinxronlash o'chiq)"),
          SyncState.idle => (Icons.cloud_queue, Colors.grey, 'Kutilmoqda'),
          SyncState.syncing => (Icons.cloud_sync, Colors.blue, 'Sinxronlanmoqda...'),
          SyncState.ok => (Icons.cloud_done, Colors.green, 'Sinxronlangan ${s.lastSyncAt == null ? '' : Fmt.time(s.lastSyncAt!)}'),
          SyncState.offline => (Icons.wifi_off, Colors.orange, s.message),
          SyncState.error => (Icons.error_outline, Colors.red, s.message),
        };
        final pending = s.pending > 0 ? '\nYuborilmagan: ${s.pending}' : '';
        final canSync = ref.watch(currentRoleProvider) != null && s.state != SyncState.disabled;
        return IconButton(
          tooltip: '$text$pending',
          onPressed: canSync ? service.syncNow : null,
          icon: Badge(
            isLabelVisible: s.pending > 0 && s.state != SyncState.disabled,
            label: Text('${s.pending}'),
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }
}

/// Rollarga bog'liq qisqa yordamchi.
bool isAdmin(WidgetRef ref) => ref.read(currentRoleProvider) == UserRole.admin;
