import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/activity_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/stats_repository.dart';
import '../../services/sync/sync_service.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import '../shell/home_shell.dart';

final _branchTodayProvider = StreamProvider.family<PeriodSummary, String>(
    (ref, id) => ref.watch(statsRepoProvider).summaryOf(DayRange.today(), id));

final _branchLowStockProvider =
    StreamProvider.family<int, String>((ref, id) => ref.watch(statsRepoProvider).watchLowStockCount(id));

final _branchCustomerDebtProvider = StreamProvider.family<CustomerDebtSummary, String>(
    (ref, id) => ref.watch(customerRepoProvider).summaryOf(id));

final _branchSupplierDebtProvider =
    StreamProvider.family<int, String>((ref, id) => ref.watch(supplierRepoProvider).watchTotalDebtOf(id));

final _recentSalesProvider = StreamProvider<List<Sale>>((ref) {
  final ids = ref.watch(accessibleBranchesProvider).map((b) => b.id).toList();
  return ref.watch(statsRepoProvider).watchRecentSales(ids, limit: 30);
});

final _recentChangesProvider = StreamProvider<List<ActivityEntry>>((ref) {
  final ids = ref.watch(accessibleBranchesProvider).map((b) => b.id).toList();
  return ref.watch(activityRepoProvider).watchRecent(ids, limit: 15);
});

/// Jonli monitoring: barcha filiallarning bugungi savdosi, oxirgi cheklar va
/// o'zgarishlar. Ochiq turganda har 5 soniyada server bilan sinxronlanadi —
/// telefondan internet (Tailscale) orqali do'konni real vaqtda kuzatish uchun.
class MonitoringPage extends ConsumerStatefulWidget {
  const MonitoringPage({super.key});

  @override
  ConsumerState<MonitoringPage> createState() => _MonitoringPageState();
}

class _MonitoringPageState extends ConsumerState<MonitoringPage> {
  static const _interval = Duration(seconds: 5);
  Timer? _timer;
  bool _live = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    if (!_live) return;
    final sync = ref.read(syncServiceProvider);
    unawaited(sync.syncNow());
    _timer = Timer.periodic(_interval, (_) => sync.syncNow());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final branches = ref.watch(accessibleBranchesProvider);
    final width = MediaQuery.sizeOf(context).width;
    final cols = width >= 1300 ? 3 : (width >= 700 ? 2 : 1);
    final names = {for (final b in branches) b.id: b.name};
    var total = 0, count = 0, profit = 0;
    final fin = _Finance();
    for (final b in branches) {
      final s = ref.watch(_branchTodayProvider(b.id)).value;
      total += s?.total ?? 0;
      count += s?.count ?? 0;
      profit += s?.profit ?? 0;
      final c = ref.watch(_branchCustomerDebtProvider(b.id)).value;
      fin
        ..sales += s?.total ?? 0
        ..collected += s?.collected ?? 0
        ..debtSold += s?.debt ?? 0
        ..debtPaidToday += c?.paidToday ?? 0
        ..customerDebt += c?.totalDebt ?? 0
        ..debtors += c?.debtorCount ?? 0
        ..supplierDebt += ref.watch(_branchSupplierDebtProvider(b.id)).value ?? 0;
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      _LiveHeader(
        live: _live,
        onLive: (v) {
          setState(() => _live = v);
          _start();
        },
      ),
      const SizedBox(height: 12),
      if (branches.length > 1) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 24, runSpacing: 8, children: [
              _Big(label: 'Bugun jami (${branches.length} filial)', value: Fmt.money(total)),
              _Big(label: 'Cheklar', value: '$count'),
              _Big(label: 'Foyda', value: Fmt.money(profit)),
            ]),
          ),
        ),
        const SizedBox(height: 12),
      ],
      _FinanceCard(fin: fin, branches: branches.length),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - (cols - 1) * 12) / cols;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final b in branches) SizedBox(width: w, child: _BranchCard(branch: b)),
        ]);
      }),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 900;
        final sales = SectionCard(title: 'Oxirgi cheklar', child: _RecentSales(names: names));
        final changes = SectionCard(
          title: "Bugungi o'zgarishlar",
          trailing: TextButton(
            onPressed: () => ref.read(shellNavProvider.notifier).open("O'zgarishlar"),
            child: const Text('Hammasi'),
          ),
          child: _RecentChanges(names: names),
        );
        if (!wide) return Column(children: [sales, const SizedBox(height: 12), changes]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: sales),
          const SizedBox(width: 12),
          Expanded(child: changes),
        ]);
      }),
    ]);
  }
}

class _LiveHeader extends ConsumerWidget {
  const _LiveHeader({required this.live, required this.onLive});
  final bool live;
  final ValueChanged<bool> onLive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncServiceProvider);
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: sync.status,
      builder: (context, s, _) {
        final theme = Theme.of(context);
        if (s.state == SyncState.disabled) {
          return Card(
            color: theme.colorScheme.secondaryContainer,
            child: ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text("Faqat shu qurilma ma'lumoti ko'rinmoqda"),
              subtitle: const Text(
                "Boshqa kassalar va filiallarni real vaqtda ko'rish uchun Sozlamalar → Sinxronlashda "
                "PosServer manzilini kiriting. Do'kondan tashqarida — internet orqali Tailscale manzili bilan.",
              ),
              trailing: TextButton(
                onPressed: () => ref.read(shellNavProvider.notifier).open('Sozlamalar'),
                child: const Text('Sozlash'),
              ),
            ),
          );
        }
        final (color, text) = switch (s.state) {
          SyncState.ok => (Colors.green, 'Ulangan · yangilandi ${s.lastSyncAt == null ? '' : _hms(s.lastSyncAt!)}'),
          SyncState.syncing => (Colors.blue, 'Yangilanmoqda...'),
          SyncState.offline => (Colors.orange, "Server bilan aloqa yo'q — oxirgi ma'lumot ko'rsatilmoqda"),
          SyncState.error => (Colors.red, s.message),
          _ => (Colors.grey, 'Kutilmoqda'),
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(Icons.circle, size: 12, color: live ? color : Colors.grey),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
              const Text('Jonli'),
              Switch(value: live, onChanged: onLive),
            ]),
          ),
        );
      },
    );
  }

  static String _hms(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
}

class _Big extends StatelessWidget {
  const _Big({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: t.labelMedium),
      Text(value, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
    ]);
  }
}

/// Barcha (ko'rinadigan) filiallar bo'yicha pul holati.
class _Finance {
  int sales = 0, collected = 0, debtSold = 0, debtPaidToday = 0;
  int customerDebt = 0, debtors = 0, supplierDebt = 0;

  /// Bugun kassaga haqiqatda kelgan pul: savdodan olingan + nasiyadan undirilgan.
  int get cashIn => collected + debtPaidToday;
}

class _FinanceCard extends StatelessWidget {
  const _FinanceCard({required this.fin, required this.branches});
  final _Finance fin;
  final int branches;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;
    final orange = Colors.orange.shade800;
    final green = Colors.green.shade700;
    Widget tile(String label, int value, {Color? color, String? hint, IconData? icon}) => SizedBox(
          width: 230,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 4)],
              Flexible(child: Text(label, style: theme.textTheme.labelMedium)),
            ]),
            Text(Fmt.money(value),
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, color: color)),
            if (hint != null) Text(hint, style: theme.textTheme.bodySmall),
          ]),
        );
    return SectionCard(
      title: branches > 1 ? 'Pul holati ($branches filial)' : 'Pul holati',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Bugun', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 24, runSpacing: 12, children: [
          tile('Savdo jami', fin.sales, icon: Icons.point_of_sale),
          tile("Qo'lga tushgan (daromadga qo'shilgan)", fin.collected,
              color: green, icon: Icons.check_circle_outline, hint: 'naqd + karta + o\'tkazma'),
          tile("Nasiyaga ketgan (hali olinmagan)", fin.debtSold,
              color: orange, icon: Icons.hourglass_bottom, hint: "daromadga qo'shilmagan"),
          tile('Nasiyadan undirilgan', fin.debtPaidToday, color: green, icon: Icons.call_received),
          tile('Joriy daromad (kassaga kelgan)', fin.cashIn,
              color: green, icon: Icons.account_balance_wallet_outlined, hint: "qo'lga tushgan + undirilgan nasiya"),
        ]),
        const Divider(height: 28),
        Text('Qarzlar (umumiy)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 24, runSpacing: 12, children: [
          tile('Mijozlardagi nasiyamiz', fin.customerDebt,
              color: orange, icon: Icons.people_outline, hint: '${fin.debtors} ta mijoz · hali olinmagan'),
          tile('Firmalarga qarzimiz', fin.supplierDebt, color: red, icon: Icons.local_shipping_outlined),
        ]),
      ]),
    );
  }
}

class _BranchCard extends ConsumerWidget {
  const _BranchCard({required this.branch});
  final Branch branch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(_branchTodayProvider(branch.id)).value ?? const PeriodSummary();
    final low = ref.watch(_branchLowStockProvider(branch.id)).value ?? 0;
    final current = ref.watch(currentBranchProvider) == branch.id;
    final theme = Theme.of(context);
    return Card(
      shape: current
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: current
            ? () => ref.read(shellNavProvider.notifier).open('Dashboard')
            : () => ref.read(currentBranchProvider.notifier).select(branch.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.store, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(branch.name,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis),
              ),
              if (current) const Chip(label: Text('Joriy'), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 8),
            Text(Fmt.money(s.total), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text("${s.count} chek · o'rtacha ${Fmt.money(s.average)}", style: theme.textTheme.bodySmall),
            Text('Foyda: ${Fmt.money(s.profit)} · naqd ${Fmt.money(s.cash)} · karta ${Fmt.money(s.card)}',
                style: theme.textTheme.bodySmall),
            if (s.debt > 0)
              Text('Nasiyaga: ${Fmt.money(s.debt)} (hali olinmagan)',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.orange.shade800)),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: low > 0 ? theme.colorScheme.error : Colors.grey),
              const SizedBox(width: 4),
              Text(low > 0 ? 'Kam qoldiq: $low ta tovar' : 'Qoldiqlar joyida',
                  style: theme.textTheme.bodySmall?.copyWith(color: low > 0 ? theme.colorScheme.error : null)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _RecentSales extends ConsumerWidget {
  const _RecentSales({required this.names});
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_recentSalesProvider).value ?? const <Sale>[];
    if (list.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text("Hali savdo yo'q"));
    final multi = names.length > 1;
    return Column(children: [
      for (final s in list)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            s.status == SaleStatus.refunded.code ? Icons.undo : Icons.receipt_long_outlined,
            color: s.status == SaleStatus.refunded.code ? Theme.of(context).colorScheme.error : null,
          ),
          title: Text('${s.receiptNo} · ${Fmt.money(s.total)}'),
          subtitle: Text([
            if (multi) names[s.branchId] ?? '',
            s.cashierName,
            PaymentType.fromCode(s.paymentType).label,
            if (s.status == SaleStatus.refunded.code) 'qaytarilgan',
          ].where((x) => x.isNotEmpty).join(' · ')),
          trailing: Text(_when(s.createdAt)),
        ),
    ]);
  }
}

class _RecentChanges extends ConsumerWidget {
  const _RecentChanges({required this.names});
  final Map<String, String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_recentChangesProvider).value ?? const <ActivityEntry>[];
    if (list.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text("Bugun o'zgarish yo'q"));
    return Column(children: [
      for (final e in list)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(activityIcon(e.kind)),
          title: Text(e.title),
          subtitle: Text([
            e.details,
            if (names.length > 1 && e.branchId.isNotEmpty) names[e.branchId] ?? '',
            e.userName,
          ].where((x) => x.isNotEmpty).join(' · ')),
          trailing: Text(Fmt.time(DateTime.fromMillisecondsSinceEpoch(e.at))),
        ),
    ]);
  }
}

IconData activityIcon(ActivityKind k) => switch (k) {
  ActivityKind.product => Icons.inventory_2_outlined,
  ActivityKind.stock => Icons.swap_vert,
  ActivityKind.sale => Icons.point_of_sale,
  ActivityKind.supplier => Icons.local_shipping_outlined,
  ActivityKind.staff => Icons.badge_outlined,
  ActivityKind.other => Icons.info_outline,
};

String _when(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  return today ? Fmt.time(d) : Fmt.dateTime(d);
}
