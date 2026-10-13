import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/supplier_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'purchase_detail_page.dart';
import 'supplier_widgets.dart';

/// Bitta firma: qarz, kirimlar (prays-listlar), to'lovlar tarixi va akt-sverka.
class SupplierDetailPage extends ConsumerWidget {
  const SupplierDetailPage({super.key, required this.supplierId});
  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplier = ref.watch(supplierProvider(supplierId)).value;
    final purchases = ref.watch(supplierPurchasesProvider(supplierId)).value ?? const <SupplierPurchase>[];
    final payments = ref.watch(supplierPaymentsProvider(supplierId)).value ?? const <SupplierPayment>[];
    final purchased = purchases.fold<int>(0, (s, p) => s + p.total);
    final paid = payments.fold<int>(0, (s, p) => s + p.amount);
    final debt = purchased - paid;
    final isAdmin = ref.watch(authProvider.notifier).isAdmin;

    if (supplier == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    Future<void> menu(String v) async {
      final repo = ref.read(supplierRepoProvider);
      switch (v) {
        case 'edit':
          await openSupplierForm(context, ref, supplier: supplier);
        case 'manual':
          final amount = await askNumber(
            context,
            title: "Qo'lda qarz qo'shish (tovarsiz)",
            suffix: "so'm",
            decimal: false,
          );
          if (amount == null || amount <= 0) return;
          final user = ref.read(authProvider)!;
          await repo.createPurchase(
            supplierId: supplier.id,
            lines: const [],
            kind: PurchaseKind.opening,
            total: amount.round(),
            note: "Qo'lda kiritilgan qarz",
            userId: user.id,
            userName: user.fullName,
          );
          ref.read(syncServiceProvider).requestSync();
        case 'delete':
          final ok = await confirmDialog(
            context,
            "Firmani o'chirish",
            '"${supplier.name}" o\'chirilsinmi?',
            ok: "O'chirish",
            danger: true,
          );
          if (!ok) return;
          try {
            await repo.deleteSupplier(supplier.id);
            ref.read(syncServiceProvider).requestSync();
            if (context.mounted) Navigator.pop(context);
          } catch (e) {
            if (context.mounted) showMessage(context, e.toString().replaceFirst('Exception: ', ''), error: true);
          }
      }
    }

    final theme = Theme.of(context);
    final header = Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(debt >= 0 ? 'Qarz' : 'Avans', style: theme.textTheme.labelLarge),
                Text(
                  Fmt.money(debt.abs()),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: debtColor(context, debt),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Jami kirim: ${Fmt.money(purchased)} · To\'langan: ${Fmt.money(paid)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (supplier.phone.isNotEmpty || supplier.contactPerson.isNotEmpty)
                  Text(
                    [supplier.contactPerson, supplier.phone].where((e) => e.isNotEmpty).join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            FilledButton.icon(
              onPressed: () => openPaymentDialog(context, ref, supplier: supplier, debt: debt),
              icon: const Icon(Icons.payments_outlined),
              label: const Text("To'lov qilish"),
            ),
          ],
        ),
      ),
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(supplier.name),
          actions: [
            PopupMenuButton<String>(
              onSelected: menu,
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Tahrirlash')),
                const PopupMenuItem(value: 'manual', child: Text("Qo'lda qarz qo'shish")),
                if (isAdmin) const PopupMenuItem(value: 'delete', child: Text("Firmani o'chirish")),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            header,
            TabBar(
              tabs: [
                Tab(text: 'Kirimlar (${purchases.length})'),
                Tab(text: "To'lovlar (${payments.length})"),
                const Tab(text: 'Akt-sverka'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _PurchasesTab(supplier: supplier, purchases: purchases, paid: paid),
                  _PaymentsTab(payments: payments, purchases: purchases, isAdmin: isAdmin),
                  _LedgerTab(purchases: purchases, payments: payments),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PurchasesTab extends StatelessWidget {
  const _PurchasesTab({required this.supplier, required this.purchases, required this.paid});
  final Supplier supplier;
  final List<SupplierPurchase> purchases;
  final int paid;

  @override
  Widget build(BuildContext context) {
    if (purchases.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        text: "Bu firmadan hali kirim yo'q.\nOmbor → Kirim bo'limida firmani tanlab kirim qiling.",
      );
    }
    final rows = SupplierRepository.allocate(purchases, paid);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final r = rows[i];
        final p = r.purchase;
        final opening = PurchaseKind.fromCode(p.kind) == PurchaseKind.opening;
        final photos = splitImagePaths(p.imagePaths);
        final status = r.isPaid
            ? ("To'langan", Colors.green.shade700)
            : r.covered > 0
            ? ('Qisman · qoldi ${Fmt.money(r.remaining)}', Colors.orange.shade800)
            : ('To\'lanmagan', Theme.of(context).colorScheme.error);
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseDetailPage(purchaseId: p.id))),
            leading: photos.isNotEmpty
                ? ProductThumb(imagePath: photos.first, size: 48, fallback: const Icon(Icons.image_outlined))
                : Icon(opening ? Icons.history_edu_outlined : Icons.receipt_long_outlined, size: 32),
            title: Text(
              opening
                  ? PurchaseKind.opening.label
                  : '${Fmt.dateMs(p.docDate)}${p.docNo.isEmpty ? '' : ' · №${p.docNo}'}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              [
                if (opening) Fmt.dateMs(p.docDate),
                if (!opening) '${Fmt.qty(p.itemCount)} dona tovar',
                if (photos.isNotEmpty) '${photos.length} ta surat',
                status.$1,
              ].join(' · '),
              style: TextStyle(color: status.$2),
            ),
            trailing: Text(Fmt.money(p.total), style: Theme.of(context).textTheme.titleMedium),
          ),
        );
      },
    );
  }
}

class _PaymentsTab extends ConsumerWidget {
  const _PaymentsTab({required this.payments, required this.purchases, required this.isAdmin});
  final List<SupplierPayment> payments;
  final List<SupplierPurchase> purchases;
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (payments.isEmpty) return const EmptyState(icon: Icons.payments_outlined, text: "Hali to'lov qilinmagan");
    final docNo = {for (final p in purchases) p.id: p};
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: payments.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final m = payments[i];
        final doc = m.purchaseId == null ? null : docNo[m.purchaseId];
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.payments_outlined),
            title: Text(Fmt.money(m.amount), style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              [
                Fmt.dateTimeMs(m.paidAt),
                PaymentType.fromCode(m.method).label,
                if (doc != null) 'kirim ${Fmt.dateMs(doc.docDate)}${doc.docNo.isEmpty ? '' : ' №${doc.docNo}'}',
                if (m.note.isNotEmpty) m.note,
                if (m.userName.isNotEmpty) m.userName,
              ].join(' · '),
            ),
            trailing: isAdmin
                ? IconButton(
                    tooltip: "To'lovni bekor qilish",
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        "To'lovni bekor qilish",
                        "${Fmt.money(m.amount)} to'lov o'chirilsinmi? Qarz shuncha oshadi.",
                        ok: "O'chirish",
                        danger: true,
                      );
                      if (!ok) return;
                      await ref.read(supplierRepoProvider).deletePayment(m.id);
                      ref.read(syncServiceProvider).requestSync();
                    },
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _LedgerTab extends StatelessWidget {
  const _LedgerTab({required this.purchases, required this.payments});
  final List<SupplierPurchase> purchases;
  final List<SupplierPayment> payments;

  @override
  Widget build(BuildContext context) {
    final rows = SupplierRepository.ledger(purchases, payments);
    if (rows.isEmpty) return const EmptyState(icon: Icons.table_rows_outlined, text: "Hisob-kitob yo'q");
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = rows[i];
        final isPurchase = e.purchase != null;
        return ListTile(
          dense: true,
          onTap: isPurchase
              ? () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => PurchaseDetailPage(purchaseId: e.purchase!.id)))
              : null,
          leading: Icon(
            isPurchase ? Icons.add_circle_outline : Icons.remove_circle_outline,
            color: isPurchase ? theme.colorScheme.error : Colors.green.shade700,
          ),
          title: Text(e.title),
          subtitle: Text(Fmt.dateMs(e.at)),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                isPurchase ? '+${Fmt.money(e.debit)}' : '−${Fmt.money(e.credit)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isPurchase ? theme.colorScheme.error : Colors.green.shade700,
                ),
              ),
              Text('qoldiq: ${Fmt.money(e.balance)}', style: theme.textTheme.bodySmall),
            ],
          ),
        );
      },
    );
  }
}
