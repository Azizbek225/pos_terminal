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
    final kind = PurchaseKind.fromCode(p.kind);
    final opening = kind == PurchaseKind.opening;
    final credit = kind == PurchaseKind.credit;
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
            : credit
            ? "Bu yozuv o'chiriladi${items.isEmpty ? '' : ' va tovarlar omborga qaytariladi'}. "
                  "Qarz ${Fmt.money(-p.total)} ga oshadi. Davom etilsinmi?"
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
                    type: credit ? MovementType.receipt : MovementType.supplierReturn,
                    qty: credit ? it.qty : -it.qty,
                    unitCost: it.price,
                    refId: p.id,
                    note: '${credit ? 'Qaytarish' : 'Kirim'} bekor qilindi: ${p.supplierName}',
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

    Future<void> shortage() async {
      final created = await openShortageDialog(context, ref, purchase: p, items: items);
      if (created && context.mounted) showMessage(context, 'Qarzdan ayrildi');
    }

    final statusText = status == null || credit
        ? ''
        : status.isPaid
        ? "To'liq to'langan"
        : status.covered > 0
        ? "Qisman to'langan · qoldi ${Fmt.money(status.remaining)}"
        : "To'lanmagan";

    return Scaffold(
      appBar: AppBar(
        title: Text(kind == PurchaseKind.purchase ? 'Kirim ${Fmt.dateMs(p.docDate)}' : kind.label),
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
                  credit ? 'Qarzdan ayrildi: ${Fmt.money(-p.total)}' : 'Summa: ${Fmt.money(p.total)}',
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
                for (final m in linked)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        if (m.signaturePath.isNotEmpty) ...[
                          InkWell(
                            onTap: () => openPhotoViewer(context, [m.signaturePath]),
                            child: Container(
                              width: 80,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: theme.colorScheme.outlineVariant),
                              ),
                              child: SignatureImage(name: m.signaturePath),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            "Shu kirimda to'langan: ${Fmt.money(m.amount)} · ${Fmt.dateMs(m.paidAt)}"
                            "${m.receivedBy.isEmpty ? '' : ' · oldi: ${m.receivedBy}'}",
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
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
                if (supplier != null && !deleted && kind == PurchaseKind.purchase && items.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: shortage,
                    icon: const Icon(Icons.remove_shopping_cart_outlined),
                    label: const Text('Kam keldi / firmaga qaytarish'),
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
                          trailing: Text(Fmt.money(p.total.abs()), style: theme.textTheme.titleMedium),
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

/// Kirimdagi tovarlardan qaysi biri qancha kam kelgani (yoki qaytarilgani).
/// Kiritilgan miqdor ombordan ayriladi va summasi qarzdan chegiriladi.
Future<bool> openShortageDialog(
  BuildContext context,
  WidgetRef ref, {
  required SupplierPurchase purchase,
  required List<SupplierPurchaseItem> items,
}) async {
  final qty = {for (final it in items) it.id: 0.0};
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final sum = items.fold<int>(0, (s, it) => s + ((qty[it.id] ?? 0) * it.price).round());
        return AlertDialog(
          title: const Text('Kam keldi / firmaga qaytarish'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Kelmagan yoki qaytarilgan miqdorni kiriting. Tovar ombordan ayriladi, summasi qarzdan "
                  "chegiriladi (qarz minusga o'tsa — firma sizga qarz).",
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final it in items)
                        ListTile(
                          dense: true,
                          title: Text(it.productName),
                          subtitle: Text('Kirim: ${Fmt.qty(it.qty)} ${it.unit} × ${Fmt.money(it.price)}'),
                          trailing: ActionChip(
                            label: Text((qty[it.id] ?? 0) == 0 ? '0' : '−${Fmt.qty(qty[it.id]!)} ${it.unit}'),
                            onPressed: () async {
                              final v = await askNumber(c, title: '${it.productName}: kam kelgan', suffix: it.unit);
                              if (v != null) setState(() => qty[it.id] = v.clamp(0, it.qty).toDouble());
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Izoh (ixtiyoriy)'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Qarzdan ayriladi: ${Fmt.money(sum)}',
                  style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Bekor qilish')),
            FilledButton(onPressed: sum > 0 ? () => Navigator.pop(c, true) : null, child: const Text('Saqlash')),
          ],
        );
      },
    ),
  );
  final reason = note.text.trim();
  note.dispose();
  if (ok != true) return false;
  final user = ref.read(authProvider)!;
  final lines = [
    for (final it in items)
      if ((qty[it.id] ?? 0) > 0)
        PurchaseLineInput(
          productId: it.productId,
          productName: it.productName,
          barcode: it.barcode,
          unit: it.unit,
          qty: qty[it.id]!,
          price: it.price,
        ),
  ];
  final doc = purchase.docNo.isEmpty ? Fmt.dateMs(purchase.docDate) : '№${purchase.docNo}';
  final id = await ref
      .read(supplierRepoProvider)
      .createCredit(
        supplierId: purchase.supplierId,
        lines: lines,
        docNo: purchase.docNo,
        note: reason.isEmpty ? 'Kirim $doc dan' : 'Kirim $doc: $reason',
        userId: user.id,
        userName: user.fullName,
      );
  final touched = await ref
      .read(stockRepoProvider)
      .addMovements(
        [
          for (final l in lines)
            MovementInput(
              productId: l.productId,
              type: MovementType.supplierReturn,
              qty: -l.qty,
              unitCost: l.price,
              refId: id,
              note: 'Kam keldi / qaytarildi: ${purchase.supplierName} $doc',
            ),
        ],
        userId: user.id,
        userName: user.fullName,
      );
  await ref.read(alertServiceProvider).checkStock(touched);
  ref.read(syncServiceProvider).requestSync();
  return true;
}
