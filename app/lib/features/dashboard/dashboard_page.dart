import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories/stats_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import '../shell/home_shell.dart';

/// Dashboard davrlari.
enum Period {
  today('Bugun'),
  yesterday('Kecha'),
  week('Hafta'),
  month('Oy');

  const Period(this.label);
  final String label;

  DayRange get range => switch (this) {
        Period.today => DayRange.today(),
        Period.yesterday => DayRange.yesterday(),
        Period.week => DayRange.thisWeek(),
        Period.month => DayRange.thisMonth(),
      };
}

final _summaryProvider = StreamProvider.family<PeriodSummary, Period>(
    (ref, p) => ref.watch(statsRepoProvider).watchSummary(p.range));

final _topProvider = StreamProvider.family<List<ProductSales>, Period>(
    (ref, p) => ref.watch(statsRepoProvider).watchTopProducts(p.range, limit: 10));

final _cashierProvider = StreamProvider.family<List<CashierSales>, Period>(
    (ref, p) => ref.watch(statsRepoProvider).watchByCashier(p.range));

final _dailyProvider = StreamProvider<List<DailyPoint>>((ref) => ref.watch(statsRepoProvider).watchDaily(days: 14));

final _inventoryValueProvider = StreamProvider((ref) => ref.watch(stockRepoProvider).watchInventoryValue());

final _recentAlertsProvider = StreamProvider<List<Alert>>(
    (ref) => ref.watch(alertRepoProvider).watchAll(unreadOnly: true, limit: 8));

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  Period _period = Period.today;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = width >= 1300 ? 4 : (width >= 700 ? 2 : 1);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // --- Davr kartalari: bugun / kecha / hafta / oy ---
        LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(spacing: 12, runSpacing: 12, children: [
            for (final p in Period.values) SizedBox(width: w, child: _PeriodCard(period: p)),
          ]);
        }),
        const SizedBox(height: 12),
        const _TargetCard(),
        const SizedBox(height: 12),
        SectionCard(title: 'Oxirgi 14 kunlik savdo', child: const SizedBox(height: 240, child: _DailyChart())),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<Period>(
            segments: [for (final p in Period.values) ButtonSegment(value: p, label: Text(p.label))],
            selected: {_period},
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
        ),
        const SizedBox(height: 12),
        _Responsive(children: [
          SectionCard(title: 'Top sotilgan tovarlar — ${_period.label.toLowerCase()}', child: _TopProducts(period: _period)),
          SectionCard(title: 'Kassirlar bo\'yicha — ${_period.label.toLowerCase()}', child: _ByCashier(period: _period)),
        ]),
        const SizedBox(height: 12),
        const _Responsive(children: [
          SectionCard(title: 'Real-time qoldiq: kam qolgan tovarlar', child: _LowStock()),
          SectionCard(title: "O'qilmagan alertlar", child: _RecentAlerts()),
        ]),
        const SizedBox(height: 12),
        const _InventoryValueCard(),
      ],
    );
  }
}

class _Responsive extends StatelessWidget {
  const _Responsive({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < 1000) {
      return Column(children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 12), children[i]],
      ]);
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: children[i])],
      ]),
    );
  }
}

class _PeriodCard extends ConsumerWidget {
  const _PeriodCard({required this.period});
  final Period period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(_summaryProvider(period)).value ?? const PeriodSummary();
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(period.label, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(Fmt.money(s.total), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          _kv('Cheklar', '${s.count}'),
          _kv("O'rtacha chek", Fmt.money(s.average)),
          _kv('Foyda (taxminiy)', Fmt.money(s.profit), color: AppTheme.success(context)),
          _kv('Chegirmalar', Fmt.money(s.discount)),
          const Divider(),
          _kv('Naqd', Fmt.money(s.cash)),
          _kv('Karta', Fmt.money(s.card)),
          _kv("O'tkazma", Fmt.money(s.transfer)),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(k)),
          Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}

class _TargetCard extends ConsumerWidget {
  const _TargetCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(dailyTargetProvider);
    final today = ref.watch(todaySummaryProvider).value?.total ?? 0;
    if (target <= 0) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.flag_outlined),
          title: Text('Kunlik savdo maqsadi belgilanmagan'),
          subtitle: Text('Sozlamalar > Alertlar bo\'limida kunlik maqsadni kiriting'),
        ),
      );
    }
    final pct = today / target;
    final color = pct >= 1 ? AppTheme.success(context) : (pct >= 0.6 ? AppTheme.warning(context) : Theme.of(context).colorScheme.error);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.flag, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text('Kunlik maqsad: ${Fmt.money(today)} / ${Fmt.money(target)}')),
            Text('${(pct * 100).toStringAsFixed(0)}%', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: pct.clamp(0, 1), minHeight: 10, color: color, borderRadius: BorderRadius.circular(6)),
        ]),
      ),
    );
  }
}

class _DailyChart extends ConsumerWidget {
  const _DailyChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_dailyProvider).value ?? const [];
    if (data.isEmpty) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final maxY = data.fold<int>(0, (m, e) => e.total > m ? e.total : m);
    return BarChart(
      BarChartData(
        maxY: maxY == 0 ? 1000 : maxY * 1.15,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, _) => BarTooltipItem(
              '${Fmt.date(data[group.x].day)}\n${Fmt.money(rod.toY)}\n${data[group.x].count} chek',
              const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              getTitlesWidget: (v, meta) => Text(_short(v), style: theme.textTheme.labelSmall),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= data.length) return const SizedBox();
                final d = data[i].day;
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${d.day}\n${Fmt.weekdayShort[d.weekday - 1]}',
                      textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
                );
              },
              reservedSize: 34,
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < data.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: data[i].total.toDouble(),
                width: 16,
                color: i == data.length - 1 ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.55),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ]),
        ],
      ),
    );
  }

  static String _short(double v) {
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)} mln';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(0)} ming';
    return v.toStringAsFixed(0);
  }
}

class _TopProducts extends ConsumerWidget {
  const _TopProducts({required this.period});
  final Period period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_topProvider(period)).value ?? const [];
    if (list.isEmpty) return const EmptyState(icon: Icons.bar_chart, text: "Bu davrda sotuv yo'q");
    final maxQty = list.first.qty;
    return Column(children: [
      for (var i = 0; i < list.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 24, child: Text('${i + 1}.')),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                LinearProgressIndicator(value: maxQty == 0 ? 0 : list[i].qty / maxQty, minHeight: 4),
              ]),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: Text('${Fmt.qty(list[i].qty)} · ${Fmt.money(list[i].revenue)}', textAlign: TextAlign.right),
            ),
          ]),
        ),
    ]);
  }
}

class _ByCashier extends ConsumerWidget {
  const _ByCashier({required this.period});
  final Period period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_cashierProvider(period)).value ?? const [];
    if (list.isEmpty) return const EmptyState(icon: Icons.person_outline, text: "Bu davrda sotuv yo'q");
    return Column(children: [
      for (final c in list)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0])),
          title: Text(c.name),
          subtitle: Text("${c.count} chek · o'rtacha ${Fmt.money(c.count == 0 ? 0 : c.total / c.count)}"),
          trailing: Text(Fmt.money(c.total), style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
    ]);
  }
}

class _LowStock extends ConsumerWidget {
  const _LowStock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(lowStockProvider).value ?? const [];
    if (list.isEmpty) {
      return const EmptyState(icon: Icons.check_circle_outline, text: "Barcha tovarlar yetarli miqdorda");
    }
    final theme = Theme.of(context);
    return Column(children: [
      for (final p in list.take(12))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(p.stockQty <= 0 ? Icons.error : Icons.warning_amber,
              color: p.stockQty <= 0 ? theme.colorScheme.error : AppTheme.warning(context)),
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text('${Fmt.qty(p.stockQty)} / min ${Fmt.qty(p.minStock)} ${p.unit}'),
        ),
      if (list.length > 12)
        TextButton(
          onPressed: () => ref.read(shellNavProvider.notifier).open('Ombor'),
          child: Text('Yana ${list.length - 12} ta — Omborda ko\'rish'),
        ),
    ]);
  }
}

class _RecentAlerts extends ConsumerWidget {
  const _RecentAlerts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_recentAlertsProvider).value ?? const [];
    if (list.isEmpty) return const EmptyState(icon: Icons.notifications_none, text: "Yangi alert yo'q");
    return Column(children: [
      for (final a in list)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(alertIcon(a.type), color: alertColor(context, a.severity)),
          title: Text(a.title),
          subtitle: Text(a.message, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(Fmt.time(DateTime.fromMillisecondsSinceEpoch(a.createdAt))),
        ),
      TextButton(
        onPressed: () => ref.read(shellNavProvider.notifier).open('Alertlar'),
        child: const Text('Barcha alertlar'),
      ),
    ]);
  }
}

class _InventoryValueCard extends ConsumerWidget {
  const _InventoryValueCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_inventoryValueProvider).value;
    if (v == null) return const SizedBox();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 32, runSpacing: 12, children: [
          _metric(context, 'Ombordagi tovarlar soni', Fmt.qty(v.totalQty)),
          _metric(context, 'Ombor qiymati (kirim narxida)', Fmt.money(v.costValue)),
          _metric(context, 'Ombor qiymati (sotuv narxida)', Fmt.money(v.saleValue)),
        ]),
      ),
    );
  }

  Widget _metric(BuildContext context, String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: Theme.of(context).textTheme.labelMedium),
        Text(v, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      ]);
}

IconData alertIcon(String type) => switch (AlertType.fromCode(type)) {
      AlertType.lowStock => Icons.inventory_2_outlined,
      AlertType.outOfStock => Icons.remove_shopping_cart_outlined,
      AlertType.dailyTarget => Icons.flag_outlined,
      AlertType.anomaly => Icons.report_gmailerrorred,
      AlertType.sync => Icons.sync_problem,
      AlertType.system => Icons.info_outline,
    };

Color alertColor(BuildContext context, String severity) => switch (AlertSeverity.fromCode(severity)) {
      AlertSeverity.critical => Theme.of(context).colorScheme.error,
      AlertSeverity.warning => AppTheme.warning(context),
      AlertSeverity.info => Theme.of(context).colorScheme.primary,
    };
