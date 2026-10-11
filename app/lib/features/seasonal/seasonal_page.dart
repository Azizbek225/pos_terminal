import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/season.dart';
import '../../data/repositories/stats_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

final _yearsProvider = FutureProvider<List<int>>((ref) {
  ref.watch(_summariesProvider(null));
  return ref.watch(statsRepoProvider).seasonYears();
});

final _summariesProvider = StreamProvider.family<List<SeasonSummary>, int?>(
    (ref, year) => ref.watch(statsRepoProvider).watchSeasonSummaries(year: year));

final _seasonTopProvider = StreamProvider.family<List<ProductSales>, (Season, int?)>(
    (ref, k) => ref.watch(statsRepoProvider).watchSeasonTop(k.$1, year: k.$2, limit: 20));

/// Mavsumiy statistika: qish/bahor/yoz/kuz bo'yicha alohida reyting.
class SeasonalPage extends ConsumerStatefulWidget {
  const SeasonalPage({super.key});

  @override
  ConsumerState<SeasonalPage> createState() => _SeasonalPageState();
}

class _SeasonalPageState extends ConsumerState<SeasonalPage> {
  Season _selected = Season.current;
  int? _year;

  static const _colors = {
    Season.winter: Color(0xFF42A5F5),
    Season.spring: Color(0xFF66BB6A),
    Season.summer: Color(0xFFFFA726),
    Season.autumn: Color(0xFF8D6E63),
  };

  @override
  Widget build(BuildContext context) {
    final current = Season.current;
    final years = ref.watch(_yearsProvider).value ?? const <int>[];
    final summaries = ref.watch(_summariesProvider(_year)).value ?? const <SeasonSummary>[];
    final top = ref.watch(_seasonTopProvider((_selected, _year))).value ?? const <ProductSales>[];
    final theme = Theme.of(context);
    final maxRev = summaries.fold<int>(0, (m, s) => s.revenue > m ? s.revenue : m);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: Text('Joriy mavsum: ${current.emoji} ${current.label} — tavsiyalar avtomatik shu mavsumga moslanadi',
              style: theme.textTheme.titleMedium),
        ),
        DropdownButton<int?>(
          value: _year,
          hint: const Text('Barcha yillar'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Barcha yillar')),
            for (final y in years) DropdownMenuItem(value: y, child: Text('$y-yil')),
          ],
          onChanged: (v) => setState(() => _year = v),
        ),
        IconButton(
          tooltip: 'Statistikani sotuvlardan qayta hisoblash',
          icon: const Icon(Icons.refresh),
          onPressed: () async {
            await ref.read(statsRepoProvider).rebuildSeasonal();
            if (context.mounted) showMessage(context, 'Mavsumiy statistika yangilandi');
          },
        ),
      ]),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 4 : 2;
        final w = (c.maxWidth - (cols - 1) * 12) / cols;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final s in Season.values)
            SizedBox(
              width: w,
              child: _SeasonCard(
                season: s,
                summary: summaries.where((x) => x.season == s).firstOrNull,
                color: _colors[s]!,
                selected: s == _selected,
                isCurrent: s == current,
                onTap: () => setState(() => _selected = s),
              ),
            ),
        ]);
      }),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Mavsumlar bo\'yicha tushum',
        child: SizedBox(
          height: 220,
          child: BarChart(BarChartData(
            maxY: maxRev == 0 ? 1000 : maxRev * 1.2,
            borderData: FlBorderData(show: false),
            gridData: const FlGridData(drawVerticalLine: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (v, _) => Text(Season.fromIndex(v.toInt()).label),
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (g, _, rod, _) =>
                    BarTooltipItem(Fmt.money(rod.toY), const TextStyle(color: Colors.white)),
              ),
            ),
            barGroups: [
              for (final s in summaries)
                BarChartGroupData(x: s.season.index0, barRods: [
                  BarChartRodData(
                    toY: s.revenue.toDouble(),
                    width: 36,
                    color: _colors[s.season],
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                ]),
            ],
          )),
        ),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: '${_selected.emoji} ${_selected.label} — eng ko\'p sotilgan tovarlar reytingi',
        child: top.isEmpty
            ? const EmptyState(icon: Icons.eco_outlined, text: "Bu mavsum uchun sotuv ma'lumotlari yo'q")
            : Column(children: [
                for (var i = 0; i < top.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: _colors[_selected]!.withValues(alpha: 0.2),
                      child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                    ),
                    title: Text(top[i].name),
                    subtitle: Text('${top[i].receipts} chek'),
                    trailing: Text('${Fmt.qty(top[i].qty)} · ${Fmt.money(top[i].revenue)}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ]),
      ),
    ]);
  }
}

class _SeasonCard extends StatelessWidget {
  const _SeasonCard({
    required this.season,
    required this.summary,
    required this.color,
    required this.selected,
    required this.isCurrent,
    required this.onTap,
  });

  final Season season;
  final SeasonSummary? summary;
  final Color color;
  final bool selected;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: selected ? color.withValues(alpha: 0.18) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? color : theme.colorScheme.outlineVariant, width: selected ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(season.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(season.label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8)),
                  child: const Text('Joriy', style: TextStyle(fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(Fmt.money(summary?.revenue ?? 0),
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Text('${Fmt.qty(summary?.qty ?? 0)} dona/birlik sotilgan', style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}
