import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/repositories/customer_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import '../suppliers/supplier_widgets.dart' show debtColor;
import 'customer_widgets.dart';

enum _Filter { debt, all }

/// Mijozlar nasiyasi: kim qancha qarz (eng ko'p qarz tepada).
class CustomerDebtsTab extends ConsumerStatefulWidget {
  const CustomerDebtsTab({super.key});

  @override
  ConsumerState<CustomerDebtsTab> createState() => _CustomerDebtsTabState();
}

class _CustomerDebtsTabState extends ConsumerState<CustomerDebtsTab> {
  String _q = '';
  _Filter _filter = _Filter.debt;

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(customerDebtSummaryProvider).value ?? const CustomerDebtSummary();
    final async = ref.watch(customerBalancesProvider);
    final all = async.value ?? const <CustomerBalance>[];
    final q = _q.trim().toLowerCase();
    final list = all.where((b) {
      if (_filter == _Filter.debt && b.debt == 0) return false;
      if (q.isEmpty) return true;
      return b.customer.name.toLowerCase().contains(q) || b.customer.phone.contains(q);
    }).toList();
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final scheme = Theme.of(context).colorScheme;

    final tiles = [
      StatTile(
        label: 'Mijozlar qarzi',
        value: Fmt.money(summary.totalDebt),
        icon: Icons.menu_book_outlined,
        color: scheme.error,
        subtitle: '${summary.debtorCount} ta mijoz',
        compact: narrow,
      ),
      StatTile(
        label: 'Bugun nasiyaga',
        value: Fmt.money(summary.debtToday),
        icon: Icons.shopping_bag_outlined,
        compact: narrow,
      ),
      StatTile(
        label: "Bugun to'landi",
        value: Fmt.money(summary.paidToday),
        icon: Icons.payments_outlined,
        color: Colors.green.shade700,
        compact: narrow,
      ),
    ];

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'customer_fab',
        onPressed: () async {
          final c = await showCustomerForm(context, ref);
          if (c != null && context.mounted) openCustomer(context, c.id);
        },
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Yangi mijoz'),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: narrow ? Column(children: tiles) : Row(children: [for (final t in tiles) Expanded(child: t)]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: narrow ? double.infinity : 320,
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Mijoz ismi yoki telefon',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            ChoiceChip(
              label: const Text('Qarzi borlar'),
              selected: _filter == _Filter.debt,
              onSelected: (_) => setState(() => _filter = _Filter.debt),
            ),
            ChoiceChip(
              label: Text('Hammasi (${all.length})'),
              selected: _filter == _Filter.all,
              onSelected: (_) => setState(() => _filter = _Filter.all),
            ),
          ]),
        ),
        Expanded(
          child: async.isLoading && all.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
              ? EmptyState(
                  icon: Icons.people_alt_outlined,
                  text: all.isEmpty
                      ? "Hali mijoz yo'q.\n\"Yangi mijoz\" tugmasi yoki savdoda \"Nasiya\" to'lovi orqali qo'shing."
                      : (_filter == _Filter.debt ? "Qarzdor mijoz yo'q" : 'Topilmadi'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (_, i) => _CustomerTile(
                    balance: list[i],
                    onTap: () => openCustomer(context, list[i].customer.id),
                  ),
                ),
        ),
      ]),
    );
  }
}

void openCustomer(BuildContext context, String id) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerDetailPage(customerId: id)));

class _CustomerTile extends StatelessWidget {
  const _CustomerTile({required this.balance, required this.onTap});
  final CustomerBalance balance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = balance.customer;
    final theme = Theme.of(context);
    final info = [
      if (c.phone.isNotEmpty) c.phone,
      if (balance.saleCount > 0) '${balance.saleCount} ta nasiya',
      if (balance.lastAt != null) 'oxirgi: ${Fmt.dateMs(balance.lastAt!)}',
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: debtColor(context, balance.debt).withValues(alpha: 0.12),
          child: Icon(Icons.person_outline, color: debtColor(context, balance.debt)),
        ),
        title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: info.isEmpty ? null : Text(info, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              balance.debt == 0 ? '0' : Fmt.money(balance.debt.abs()),
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: debtColor(context, balance.debt), fontWeight: FontWeight.bold),
            ),
            Text(
              balance.debt > 0 ? 'qarz' : (balance.debt < 0 ? 'avans' : 'yopiq'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Mijoz kartasi: qarz, to'lov qabul qilish, qarz yozish va daftar.
class CustomerDetailPage extends ConsumerWidget {
  const CustomerDetailPage({super.key, required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(customerProvider(customerId)).value;
    final debt = ref.watch(customerDebtProvider(customerId)).value ?? 0;
    final ledger = ref.watch(customerLedgerProvider(customerId)).value ?? const <CustomerLedgerEntry>[];
    final theme = Theme.of(context);

    if (customer == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(customer.name),
        actions: [
          IconButton(
            tooltip: 'Tahrirlash',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showCustomerForm(context, ref, customer: customer),
          ),
          IconButton(
            tooltip: "O'chirish",
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirmDialog(context, "Mijozni o'chirish", "${customer.name} o'chirilsinmi?", danger: true)) {
                return;
              }
              try {
                await ref.read(customerRepoProvider).delete(customer.id);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (context.mounted) showMessage(context, e.toString(), error: true);
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (customer.phone.isNotEmpty) Text(customer.phone, style: theme.textTheme.bodyLarge),
              if (customer.address.isNotEmpty) Text(customer.address),
              if (customer.note.isNotEmpty) Text(customer.note, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Text(debt > 0 ? 'Qarzi' : (debt < 0 ? 'Avans (oldindan to\'lagan)' : 'Qarzi yo\'q')),
              Text(
                Fmt.money(debt.abs()),
                style: theme.textTheme.headlineMedium
                    ?.copyWith(color: debtColor(context, debt), fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: () => showCustomerMoneyDialog(context, ref, customer, payment: true),
                  icon: const Icon(Icons.payments_outlined),
                  label: const Text("To'lov qabul qilish"),
                ),
                OutlinedButton.icon(
                  onPressed: () => showCustomerMoneyDialog(context, ref, customer, payment: false),
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Qarz yozish'),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text('Daftar', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        if (ledger.isEmpty)
          const EmptyState(icon: Icons.menu_book_outlined, text: "Hali yozuv yo'q")
        else
          Card(
            child: Column(children: [
              for (var i = 0; i < ledger.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _LedgerTile(entry: ledger[i]),
              ],
            ]),
          ),
      ]),
    );
  }
}

class _LedgerTile extends ConsumerWidget {
  const _LedgerTile({required this.entry});
  final CustomerLedgerEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = entry.entry;
    final plus = e.amount > 0;
    final color = plus ? Theme.of(context).colorScheme.error : Colors.green.shade700;
    final details = [
      Fmt.dateTime(DateTime.fromMillisecondsSinceEpoch(e.createdAt)),
      if (entry.receiptNo.isNotEmpty) 'chek ${entry.receiptNo}',
      if (e.method.isNotEmpty) PaymentType.fromCode(e.method).label,
      if (e.note.isNotEmpty && e.note != entry.receiptNo) e.note,
      if (e.userName.isNotEmpty) e.userName,
    ].join(' · ');
    final deletable = entry.kind == CustomerDebtKind.payment || entry.kind == CustomerDebtKind.manual;
    return ListTile(
      leading: Icon(switch (entry.kind) {
        CustomerDebtKind.sale => Icons.shopping_bag_outlined,
        CustomerDebtKind.manual => Icons.edit_note,
        CustomerDebtKind.payment => Icons.payments_outlined,
        CustomerDebtKind.refund => Icons.undo,
      }, color: color),
      title: Text(entry.kind.label),
      subtitle: Text(details),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('${plus ? '+' : '−'}${Fmt.money(e.amount.abs())}',
              style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          Text('qoldiq: ${Fmt.money(entry.balance)}', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      onLongPress: !deletable
          ? null
          : () async {
              if (!await confirmDialog(context, 'Yozuvni bekor qilish',
                  "${entry.kind.label} (${Fmt.money(e.amount.abs())}) bekor qilinsinmi?", danger: true)) {
                return;
              }
              await ref.read(customerRepoProvider).deleteEntry(e.id);
              ref.read(syncServiceProvider).requestSync();
            },
    );
  }
}
