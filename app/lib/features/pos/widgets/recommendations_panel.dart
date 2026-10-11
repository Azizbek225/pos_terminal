import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters.dart';
import '../../../core/season.dart';
import '../../../data/database.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../data/repositories/stats_repository.dart';
import '../../../services/product_images.dart';
import '../../../state/providers.dart';
import '../../shell/common_widgets.dart';

/// O'ng panel: "Tez-tez sotiladigan tovarlar" va "Mavsumiy tavsiyalar".
/// Ikkalasi ham Drift `watch()` oqimlariga ulangan — har bir sotuvdan keyin
/// avtomatik yangilanadi.
class RecommendationsPanel extends ConsumerWidget {
  const RecommendationsPanel({super.key, required this.onPick});
  final void Function(Product) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(children: [
      Expanded(child: FrequentSection(onPick: onPick)),
      const SizedBox(height: 10),
      Expanded(child: SeasonalSection(onPick: onPick)),
    ]);
  }
}

class FrequentSection extends ConsumerWidget {
  const FrequentSection({super.key, required this.onPick});
  final void Function(Product) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(frequentDaysProvider);
    final data = ref.watch(frequentProductsProvider);
    return _PanelCard(
      title: 'Tez-tez sotiladigan',
      icon: Icons.local_fire_department,
      iconColor: Colors.deepOrange,
      trailing: SegmentedButton<int>(
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 7, label: Text('7 kun')),
          ButtonSegment(value: 30, label: Text('30 kun')),
        ],
        selected: {days},
        onSelectionChanged: (s) => ref.read(settingsRepoProvider).set(SettingKeys.frequentDays, '${s.first}'),
      ),
      child: data.when(
        data: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.trending_up, text: "Hali sotuvlar yo'q.\nSotuvdan keyin bu yer avtomatik to'ladi.")
            : _ProductGrid(items: list, onPick: onPick),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Xato: $e')),
      ),
    );
  }
}

class SeasonalSection extends ConsumerWidget {
  const SeasonalSection({super.key, required this.onPick});
  final void Function(Product) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final season = ref.watch(currentSeasonProvider).value ?? Season.current;
    final data = ref.watch(seasonalRecsProvider);
    return _PanelCard(
      title: 'Mavsumiy tavsiyalar',
      icon: Icons.eco,
      iconColor: Colors.green,
      trailing: Chip(
        visualDensity: VisualDensity.compact,
        label: Text('${season.emoji} ${season.label}'),
      ),
      child: data.when(
        data: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.eco_outlined,
                text: '${season.label} mavsumi uchun ma\'lumot yo\'q.\n'
                    'Tovar kartasida mavsum belgilang yoki sotuvlar to\'planishini kuting.')
            : _ProductGrid(items: list, onPick: onPick, showSeasonBadge: true),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Xato: $e')),
      ),
    );
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.title, required this.icon, required this.iconColor, required this.child, this.trailing});
  final String title;
  final IconData icon;
  final Color iconColor;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
            ?trailing,
          ]),
          const SizedBox(height: 8),
          Expanded(child: child),
        ]),
      ),
    );
  }
}

class _ProductGrid extends StatelessWidget {
  const _ProductGrid({required this.items, required this.onPick, this.showSeasonBadge = false});
  final List<ProductSales> items;
  final void Function(Product) onPick;
  final bool showSeasonBadge;

  @override
  Widget build(BuildContext context) {
    final valid = items.where((e) => e.product != null).toList();
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisExtent: 96,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: valid.length,
      itemBuilder: (context, i) => _ProductTile(item: valid[i], onPick: onPick, showSeasonBadge: showSeasonBadge),
    );
  }
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.item, required this.onPick, required this.showSeasonBadge});
  final ProductSales item;
  final void Function(Product) onPick;
  final bool showSeasonBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = item.product!;
    final low = p.minStock > 0 && p.stockQty <= p.minStock;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onPick(p),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (ProductImages.resolve(p.imagePath) != null) ...[
                  ProductThumb(imagePath: p.imagePath, size: 40),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(p.name,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
            Text(Fmt.money(p.salePrice),
                style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
            Row(children: [
              Expanded(
                child: Text(
                  item.fromTagOnly ? 'Mavsum tovari' : '${Fmt.qty(item.qty)} ${p.unit} sotilgan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall,
                ),
              ),
              Icon(Icons.inventory_2, size: 12, color: low ? theme.colorScheme.error : theme.hintColor),
              Text(' ${Fmt.qty(p.stockQty)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: low ? theme.colorScheme.error : null)),
            ]),
          ]),
        ),
      ),
    );
  }
}
