import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/sale_repository.dart';
import '../../state/providers.dart';
import '../pos/widgets/receipt_dialog.dart';
import '../shell/common_widgets.dart';

final _salesProvider =
    StreamProvider.family<List<Sale>, SaleFilter>((ref, f) => ref.watch(saleRepoProvider).watchSales(f));

/// Savdo tarixi: barcha cheklar, filtrlar, chekni ko'rish va qayta chop etish.
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  late SaleFilter _filter;
  DateTimeRange? _range;
  final _min = TextEditingController();
  final _max = TextEditingController();

  @override
  void initState() {
    super.initState();
    final r = DayRange.lastDays(7);
    _range = DateTimeRange(start: r.from, end: r.to.subtract(const Duration(days: 1)));
    _filter = SaleFilter(fromMs: r.fromMs, toMs: r.toMs, limit: 2000);
    // Kassir faqat o'z cheklarini ko'radi.
    final user = ref.read(authProvider);
    if (user != null && ref.read(currentRoleProvider) == UserRole.cashier) {
      _filter = _filter.copyWith(cashierId: () => user.id);
    }
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _range,
      helpText: 'Sana oralig\'ini tanlang',
      saveText: 'Tanlash',
    );
    if (r == null) return;
    setState(() {
      _range = r;
      _filter = _filter.copyWith(
        fromMs: () => DayRange.startOfDay(r.start).millisecondsSinceEpoch,
        toMs: () => DayRange.startOfDay(r.end).add(const Duration(days: 1)).millisecondsSinceEpoch,
      );
    });
  }

  void _applyAmounts() {
    setState(() {
      _filter = _filter.copyWith(
        minTotal: () => Fmt.parseNum(_min.text)?.round(),
        maxTotal: () => Fmt.parseNum(_max.text)?.round(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentRoleProvider);
    final isAdmin = role == UserRole.admin;
    final users = ref.watch(usersProvider).value ?? const <User>[];
    final sales = ref.watch(_salesProvider(_filter));
    final theme = Theme.of(context);

    final filters = Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      OutlinedButton.icon(
        onPressed: _pickRange,
        icon: const Icon(Icons.date_range),
        label: Text(_range == null ? 'Sana' : '${Fmt.date(_range!.start)} — ${Fmt.date(_range!.end)}'),
      ),
      if (isAdmin)
        DropdownButton<String?>(
          value: _filter.cashierId,
          hint: const Text('Barcha kassirlar'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Barcha kassirlar')),
            for (final u in users) DropdownMenuItem(value: u.id, child: Text(u.fullName)),
          ],
          onChanged: (v) => setState(() => _filter = _filter.copyWith(cashierId: () => v)),
        ),
      DropdownButton<PaymentType?>(
        value: _filter.paymentType,
        hint: const Text("Barcha to'lov turlari"),
        items: [
          const DropdownMenuItem(value: null, child: Text("Barcha to'lov turlari")),
          for (final p in PaymentType.values) DropdownMenuItem(value: p, child: Text(p.label)),
        ],
        onChanged: (v) => setState(() => _filter = _filter.copyWith(paymentType: () => v)),
      ),
      DropdownButton<SaleStatus?>(
        value: _filter.status,
        hint: const Text('Barcha holatlar'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Barcha holatlar')),
          for (final s in SaleStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
        ],
        onChanged: (v) => setState(() => _filter = _filter.copyWith(status: () => v)),
      ),
      SizedBox(
        width: 130,
        child: TextField(
          controller: _min,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Summa dan', isDense: true),
          onSubmitted: (_) => _applyAmounts(),
        ),
      ),
      SizedBox(
        width: 130,
        child: TextField(
          controller: _max,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Summa gacha', isDense: true),
          onSubmitted: (_) => _applyAmounts(),
        ),
      ),
      IconButton.filledTonal(onPressed: _applyAmounts, icon: const Icon(Icons.filter_alt), tooltip: 'Filtrlash'),
      SizedBox(
        width: 180,
        child: TextField(
          decoration: const InputDecoration(labelText: 'Chek raqami', isDense: true, prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => _filter = _filter.copyWith(receiptQuery: v)),
        ),
      ),
    ]);

    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: filters),
      Expanded(
        child: sales.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Xato: $e')),
          data: (list) {
            final completed = list.where((s) => s.status == SaleStatus.completed.code);
            final sum = completed.fold<int>(0, (a, s) => a + s.total);
            return Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 24, runSpacing: 4, children: [
                  Text('Cheklar: ${list.length}', style: theme.textTheme.titleSmall),
                  Text('Jami (qaytarilganlarsiz): ${Fmt.money(sum)}',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                ]),
              ),
              Expanded(
                child: list.isEmpty
                    ? const EmptyState(icon: Icons.receipt_long_outlined, text: 'Cheklar topilmadi')
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final s = list[i];
                          final refunded = s.status == SaleStatus.refunded.code;
                          return ListTile(
                            onTap: () => showReceiptDialog(context, ref, s.id, allowRefund: true),
                            leading: CircleAvatar(
                              backgroundColor: refunded ? theme.colorScheme.errorContainer : theme.colorScheme.primaryContainer,
                              child: Icon(refunded ? Icons.undo : _payIcon(s.paymentType), size: 20),
                            ),
                            title: Text('${s.receiptNo}  ·  ${Fmt.dateTimeMs(s.createdAt)}'),
                            subtitle: Text(
                              '${s.cashierName} · ${PaymentType.fromCode(s.paymentType).label} · ${Fmt.qty(s.itemCount)} ta tovar'
                              '${s.discountAmount > 0 ? ' · chegirma ${Fmt.money(s.discountAmount)}' : ''}'
                              '${refunded ? ' · QAYTARILGAN (${s.refundedBy ?? ''})' : ''}',
                            ),
                            trailing: Text(
                              Fmt.money(s.total),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                decoration: refunded ? TextDecoration.lineThrough : null,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }

  static IconData _payIcon(String code) => switch (PaymentType.fromCode(code)) {
        PaymentType.cash => Icons.payments_outlined,
        PaymentType.card => Icons.credit_card,
        PaymentType.transfer => Icons.swap_horiz,
        PaymentType.mixed => Icons.call_split,
      };
}
