import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/stock_repository.dart';
import '../../data/repositories/supplier_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'supplier_widgets.dart';

final _purchaseProvider = StreamProvider.family<SupplierPurchase?, String>(
  (ref, id) => ref.watch(supplierRepoProvider).watchPurchase(id),
);
final _itemsProvider = StreamProvider.family<List<SupplierPurchaseItem>, String>(
  (ref, id) => ref.watch(supplierRepoProvider).watchItems(id),
);

/// Bitta kirim (prays-list): suratlar, tovarlar, soni va narxi, to'lov holati.
class PurchaseDetailPage extends ConsumerWidget {
  const PurchaseDetailPage({super.key, required this.purchaseId});
  final String purchaseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(_purchaseProvider(purchaseId)).value;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final items = ref.watch(_itemsProvider(purchaseId)).value ?? const <SupplierPurchaseItem>[];
    final supplier = ref.watch(supplierProvider(p.supplierId)).value;
    final purchases = ref.watch(supplierPurchasesProvider(p.supplierId)).value ?? const <SupplierPurchase>[];
    final payments = ref.watch(supplierPaymentsProvider(p.supplierId)).value ?? const <SupplierPayment>[];
    final paidTotal = payments.fold<int>(0, (s, m) => s + m.amount);
    final debt = purchases.fold<int>(0, (s, x) => s + x.total) - paidTotal;
    final status = SupplierRepository.allocate(purchases, paidTotal).where((r) => r.purchase.id == p.id).firstOrNull;
    final linked = payments.where((m) => m.purchaseId == p.id).toList();
    final photos = splitImagePaths(p.imagePaths);
    final isAdmin = ref.watch(authProvider.notifier).isAdmin;
    final opening = PurchaseKind.fromCode(p.kind) == PurchaseKind.opening;
    final theme = Theme.of(context);
    final deleted = p.isDeleted;

    Future<void> addPhoto(bool camera) async {
      final name = await pickDocumentPhoto(context, camera: camera);
      if (name == null) return;
      await ref.read(supplierRepoProvider).setPurchaseImages(p.id, [...photos, name]);
      ref.read(syncServiceProvider).requestSync();
    }

    Future<void> removePhoto(String name) async {
      final ok = await confirmDialog(
        context,
        "Suratni o'chirish",
        "Surat o'chirilsinmi?",
        ok: "O'chirish",
        danger: true,
      );
      if (!ok) return;
      await ref.read(supplierRepoProvider).setPurchaseImages(p.id, photos.where((n) => n != name).toList());
      ref.read(syncServiceProvider).requestSync();
    }

    Future<void> cancel() async {
      final ok = await confirmDialog(
        context,
        'Kirimni bekor qilish',
        opening
            ? "Bu qarz yozuvi o'chiriladi. Davom etilsinmi?"
            : "Kirim o'chiriladi va tovarlar ombordan ayriladi (${items.length} pozitsiya). "
                  "Qarz ${Fmt.money(p.total)} ga kamayadi. Davom etilsinmi?",
        ok: 'Bekor qilish',
        cancel: 'Yopish',
        danger: true,
      );
      if (!ok) return;
      try {
        final user = ref.read(authProvider)!;
        final removed = await ref.read(supplierRepoProvider).deletePurchase(p.id);
        final touched = await ref
            .read(stockRepoProvider)
            .addMovements(
              [
                for (final it in removed)
                  MovementInput(
                    productId: it.productId,
                    type: MovementType.supplierReturn,
                    qty: -it.qty,
                    unitCost: it.price,
                    refId: p.id,
                    note: 'Kirim bekor qilindi: ${p.supplierName}',
                  ),
              ],
              userId: user.id,
              userName: user.fullName,
            );
        await ref.read(alertServiceProvider).checkStock(touched);
        ref.read(syncServiceProvider).requestSync();
        if (context.mounted) Navigator.pop(context);
      } catch (e) {
        if (context.mounted) showMessage(context, e.toString(), error: true);
      }
    }

    final statusText = status == null
        ? ''
        : status.isPaid
        ? "To'liq to'langan"
        : status.covered > 0
        ? "Qisman to'langan · qoldi ${Fmt.money(status.remaining)}"
        : "To'lanmagan";

    return Scaffold(
      appBar: AppBar(
        title: Text(opening ? PurchaseKind.opening.label : 'Kirim ${Fmt.dateMs(p.docDate)}'),
        actions: [
          if (isAdmin && !deleted)
            IconButton(tooltip: 'Kirimni bekor qilish', icon: const Icon(Icons.delete_outline), onPressed: cancel),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (deleted)
            Card(
              color: theme.colorScheme.errorContainer,
              child: const ListTile(leading: Icon(Icons.block), title: Text('Bu kirim bekor qilingan')),
            ),
          SectionCard(
            title: p.supplierName,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sana: ${Fmt.dateMs(p.docDate)}${p.docNo.isEmpty ? '' : ' · Nakladnoy №${p.docNo}'}'),
                if (p.userName.isNotEmpty) Text('Kiritgan: ${p.userName} (${Fmt.dateTimeMs(p.createdAt)})'),
                if (p.note.isNotEmpty) Text('Izoh: ${p.note}'),
                const SizedBox(height: 8),
                Text(
                  'Summa: ${Fmt.money(p.total)}',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (statusText.isNotEmpty)
                  Text(
                    statusText,
                    style: TextStyle(
                      color: status!.isPaid ? Colors.green.shade700 : theme.colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (linked.isNotEmpty)
                  Text(
                    "Shu kirimda to'langan: ${linked.map((m) => Fmt.money(m.amount)).join(' + ')}",
                    style: theme.textTheme.bodySmall,
                  ),
                if (supplier != null && !deleted && debt > 0) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => openPaymentDialog(
                      context,
                      ref,
                      supplier: supplier,
                      debt: debt,
                      purchaseId: p.id,
                      suggested: status != null && status.remaining > 0 ? status.remaining : null,
                    ),
                    icon: const Icon(Icons.payments_outlined),
                    label: Text("To'lov qilish (firma qarzi ${Fmt.money(debt)})"),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          SectionCard(
            title: 'Prays-list / nakladnoy suratlari',
            child: DocumentPhotosStrip(
              names: photos,
              size: 96,
              onAdd: deleted ? null : addPhoto,
              onRemove: deleted ? null : removePhoto,
            ),
          ),
          if (!opening) ...[
            const SizedBox(height: 8),
            SectionCard(
              title: 'Tovarlar (${items.length})',
              padding: 8,
              child: items.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text("Tovarlar yo'q"))
                  : Column(
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            dense: true,
                            title: Text(items[i].productName),
                            subtitle: Text(
                              '${Fmt.qty(items[i].qty)} ${items[i].unit} × ${Fmt.money(items[i].price)}'
                              '${items[i].barcode.isEmpty ? '' : ' · ${items[i].barcode}'}',
                            ),
                            trailing: Text(
                              Fmt.money(items[i].lineTotal),
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          title: Text('Jami: ${Fmt.qty(items.fold<double>(0, (s, x) => s + x.qty))} dona'),
                          trailing: Text(Fmt.money(p.total), style: theme.textTheme.titleMedium),
                        ),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
