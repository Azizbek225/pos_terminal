import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/repositories/supplier_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'supplier_detail_page.dart';
import 'supplier_widgets.dart';

/// Qarzlar oynasi: umumiy qarzdorlik va firmalar ro'yxati (eng ko'p qarz tepada).
/// Firma bosilsa — uning kirimlari (prays-listlar), to'lovlari va akt-sverkasi.
class DebtsPage extends ConsumerStatefulWidget {
  const DebtsPage({super.key});

  @override
  ConsumerState<DebtsPage> createState() => _DebtsPageState();
}

enum _Filter { all, debt, closed }

class _DebtsPageState extends ConsumerState<DebtsPage> {
  String _q = '';
  _Filter _filter = _Filter.all;

  void _open(SupplierBalance b) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SupplierDetailPage(supplierId: b.supplier.id)));
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(debtSummaryProvider).value ?? const DebtSummary();
    final async = ref.watch(supplierBalancesProvider);
    final all = async.value ?? const <SupplierBalance>[];
    final q = _q.trim().toLowerCase();
    final list = all.where((b) {
      if (_filter == _Filter.debt && b.debt <= 0) return false;
      if (_filter == _Filter.closed && b.debt > 0) return false;
      if (q.isEmpty) return true;
      return b.supplier.name.toLowerCase().contains(q) ||
          b.supplier.phone.contains(q) ||
          b.supplier.contactPerson.toLowerCase().contains(q);
    }).toList();
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final scheme = Theme.of(context).colorScheme;

    final tiles = [
      StatTile(
        label: 'Umumiy qarzdorlik',
        value: Fmt.money(summary.totalDebt),
        icon: Icons.account_balance_wallet_outlined,
        color: scheme.error,
        subtitle: '${summary.debtorCount} ta firmaga',
        compact: narrow,
      ),
      StatTile(
        label: "Bugun to'langan",
        value: Fmt.money(summary.paidToday),
        icon: Icons.payments_outlined,
        color: Colors.green.shade700,
        compact: narrow,
      ),
      if (summary.totalAdvance > 0)
        StatTile(
          label: 'Firmalar sizga qarz',
          value: Fmt.money(summary.totalAdvance),
          icon: Icons.savings_outlined,
          compact: narrow,
        ),
    ];

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openSupplierForm(context, ref),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Yangi firma'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: narrow ? Column(children: tiles) : Row(children: [for (final t in tiles) Expanded(child: t)]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: narrow ? double.infinity : 320,
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Firma nomi yoki telefon',
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                for (final f in _Filter.values)
                  ChoiceChip(
                    label: Text(switch (f) {
                      _Filter.all => 'Hammasi (${all.length})',
                      _Filter.debt => 'Qarzi borlar',
                      _Filter.closed => 'Hisob yopiq',
                    }),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
              ],
            ),
          ),
          Expanded(
            child: async.isLoading && all.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                ? EmptyState(
                    icon: Icons.business_outlined,
                    text: all.isEmpty
                        ? "Hali firma yo'q.\n\"Yangi firma\" tugmasi yoki Ombor → Kirim orqali qo'shing."
                        : 'Topilmadi',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (_, i) => _SupplierTile(balance: list[i], onTap: () => _open(list[i])),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SupplierTile extends StatelessWidget {
  const _SupplierTile({required this.balance, required this.onTap});
  final SupplierBalance balance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = balance.supplier;
    final theme = Theme.of(context);
    final info = [
      if (s.phone.isNotEmpty) s.phone,
      '${balance.purchaseCount} ta kirim',
      if (balance.lastPurchaseAt != null) 'oxirgi: ${Fmt.dateMs(balance.lastPurchaseAt!)}',
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: debtColor(context, balance.debt).withValues(alpha: 0.12),
          child: Icon(Icons.business_outlined, color: debtColor(context, balance.debt)),
        ),
        title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              balance.debt == 0 ? '0' : Fmt.money(balance.debt.abs()),
              style: theme.textTheme.titleMedium?.copyWith(
                color: debtColor(context, balance.debt),
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              balance.debt > 0 ? 'qarz' : (balance.debt < 0 ? 'sizga qarz' : 'yopiq'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
