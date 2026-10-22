import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/repositories/activity_repository.dart';
import '../../state/providers.dart';
import '../monitoring/monitoring_page.dart' show activityIcon;
import '../shell/common_widgets.dart';

final _dayProvider = StreamProvider.family<ActivityDay, DateTime>((ref, day) {
  final from = DayRange.startOfDay(day);
  return ref.watch(activityRepoProvider).watchDay(DayRange(from, from.add(const Duration(days: 1))));
});

/// O'zgarishlar jurnali: tanlangan kunda nima qo'shildi, o'chirildi,
/// omborga kirdi/chiqdi, narx o'zgardi — joriy filial bo'yicha.
class ActivityPage extends ConsumerStatefulWidget {
  const ActivityPage({super.key});

  @override
  ConsumerState<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends ConsumerState<ActivityPage> {
  DateTime _day = DayRange.startOfDay(DateTime.now());
  ActivityKind? _kind;

  bool get _isToday => _day == DayRange.startOfDay(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_dayProvider(_day));
    final day = data.value ?? const ActivityDay();
    final entries = _kind == null ? day.entries : day.entries.where((e) => e.kind == _kind).toList();
    final branch = ref.watch(currentBranchNameProvider);

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        IconButton(
          tooltip: 'Oldingi kun',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
        ),
        Expanded(
          child: InkWell(
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _day,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _day = DayRange.startOfDay(d));
            },
            child: Column(children: [
              Text(_isToday ? 'Bugun, ${Fmt.date(_day)}' : Fmt.date(_day),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              if (branch.isNotEmpty) Text(branch, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
        IconButton(
          tooltip: 'Keyingi kun',
          icon: const Icon(Icons.chevron_right),
          onPressed: _isToday ? null : () => setState(() => _day = _day.add(const Duration(days: 1))),
        ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _Stat(Icons.add_box_outlined, "Qo'shilgan tovarlar", '${day.productsAdded}', Colors.green),
        _Stat(Icons.edit_outlined, "O'zgartirilgan tovarlar", '${day.productsEdited}', Colors.indigo),
        _Stat(Icons.sell_outlined, "Narx o'zgarishi", '${day.priceChanges}', Colors.purple),
        _Stat(Icons.delete_outline, "O'chirilgan tovarlar", '${day.productsDeleted}', Colors.red),
        _Stat(Icons.move_to_inbox_outlined, 'Omborga kirim',
            '${day.receiptCount} ta · ${Fmt.qty(day.receiptQty)}', Colors.teal),
        _Stat(Icons.outbox_outlined, 'Ombordan chiqarilgan',
            '${day.writeOffCount} ta · ${Fmt.qty(day.writeOffQty)}', Colors.orange),
        _Stat(Icons.fact_check_outlined, 'Inventarizatsiya', '${day.adjustmentCount}', Colors.brown),
        _Stat(Icons.point_of_sale, 'Savdo', '${day.saleCount} chek · ${Fmt.money(day.saleTotal)}', Colors.blue),
        _Stat(Icons.undo, 'Qaytarilgan cheklar', '${day.refundCount}', Colors.pink),
      ]),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('Hammasi (${day.entries.length})'),
              selected: _kind == null,
              onSelected: (_) => setState(() => _kind = null),
            ),
          ),
          for (final k in ActivityKind.values)
            if (day.entries.any((e) => e.kind == k))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  avatar: Icon(activityIcon(k), size: 18),
                  label: Text('${k.label} (${day.entries.where((e) => e.kind == k).length})'),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
              ),
        ]),
      ),
      const SizedBox(height: 8),
      if (data.isLoading && data.value == null)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
      else if (entries.isEmpty)
        const EmptyState(icon: Icons.manage_history, text: "Bu kunda o'zgarish yo'q")
      else
        Card(
          child: Column(children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                leading: Icon(activityIcon(entries[i].kind)),
                title: Text(entries[i].title),
                subtitle: Text([entries[i].details, entries[i].userName].where((x) => x.isNotEmpty).join(' · ')),
                trailing: Text(Fmt.time(DateTime.fromMillisecondsSinceEpoch(entries[i].at))),
              ),
            ],
          ]),
        ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.label, this.value, this.color);
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    return Container(
      width: screen < 520 ? (screen - 40) / 2 : 210,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: theme.textTheme.labelSmall),
            Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          ]),
        ),
      ]),
    );
  }
}
