import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

final _movementsProvider = StreamProvider.family<List<StockMovement>, int>((ref, days) {
  final r = DayRange.lastDays(days);
  return ref.watch(stockRepoProvider).watchMovements(fromMs: r.fromMs, toMs: r.toMs, limit: 1000);
});

final _allProductNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  ref.watch(_movementsProvider(7)); // harakatlar yangilanganda qayta yuklash
  final db = ref.watch(databaseProvider);
  final rows = await db.select(db.products).get();
  return {for (final p in rows) p.id: p.name};
});

/// Ombor harakatlari jurnali (kirim, sotuv, qaytarish, chiqim, inventarizatsiya).
class MovementsTab extends ConsumerStatefulWidget {
  const MovementsTab({super.key});

  @override
  ConsumerState<MovementsTab> createState() => _MovementsTabState();
}

class _MovementsTabState extends ConsumerState<MovementsTab> {
  int _days = 7;
  MovementType? _type;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(_movementsProvider(_days)).value ?? const <StockMovement>[];
    final names = ref.watch(_allProductNamesProvider).value ?? const {};
    final list = _type == null ? all : all.where((m) => m.type == _type!.code).toList();
    final theme = Theme.of(context);

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Bugun')),
              ButtonSegment(value: 7, label: Text('7 kun')),
              ButtonSegment(value: 30, label: Text('30 kun')),
              ButtonSegment(value: 365, label: Text('Yil')),
            ],
            selected: {_days},
            onSelectionChanged: (s) => setState(() => _days = s.first),
          ),
          DropdownButton<MovementType?>(
            value: _type,
            hint: const Text('Barcha turlar'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Barcha turlar')),
              for (final t in MovementType.values) DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (v) => setState(() => _type = v),
          ),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? const EmptyState(icon: Icons.swap_vert, text: "Bu davrda harakatlar yo'q")
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final m = list[i];
                  final plus = m.qty > 0;
                  final color = plus ? AppTheme.success(context) : theme.colorScheme.error;
                  return ListTile(
                    dense: true,
                    leading: Icon(plus ? Icons.south_west : Icons.north_east, color: color),
                    title: Text(names[m.productId] ?? m.productId, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${MovementType.fromCode(m.type).label} · ${Fmt.dateTimeMs(m.createdAt)}'
                        ' · ${m.userName}${m.note.isEmpty ? '' : ' · ${m.note}'}'),
                    trailing: Text('${plus ? '+' : ''}${Fmt.qty(m.qty)}',
                        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
                  );
                },
              ),
      ),
    ]);
  }
}
