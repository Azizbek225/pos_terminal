import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../services/printing/printer_config.dart';
import '../../../services/printing/receipt_layout.dart';
import '../../../state/providers.dart';
import '../../shell/common_widgets.dart';
import 'admin_approval_dialog.dart';

/// Chekni ekranda ko'rsatish (printerga chiqadigan maket bilan bir xil),
/// qayta chop etish va (Admin uchun) qaytarish.
Future<void> showReceiptDialog(BuildContext context, WidgetRef ref, String saleId, {bool allowRefund = false}) async {
  final s = await ref.read(saleRepoProvider).getWithItems(saleId);
  if (s == null || !context.mounted) return;
  final store = await ref.read(printerServiceProvider).storeInfo();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _ReceiptDialog(sale: s, store: store, allowRefund: allowRefund),
  );
}

/// Chop etish natijalarini foydalanuvchiga ko'rsatish.
Future<void> printAndReport(BuildContext context, WidgetRef ref, SaleWithItems s,
    {PrintTarget? target, bool copy = false}) async {
  final service = ref.read(printerServiceProvider);
  if (!await service.hasAnyPrinter()) {
    if (context.mounted) {
      showMessage(context, 'Printer sozlanmagan — Sozlamalar > Printerlar bo\'limida sozlang', error: true);
    }
    return;
  }
  final results = await service.printReceipt(s, target: target, copy: copy);
  if (!context.mounted) return;
  final failed = results.where((r) => !r.ok).toList();
  if (failed.isEmpty) {
    showMessage(context, 'Chek chop etildi');
  } else {
    showMessage(context, failed.map((f) => '${f.slot}-printer: ${f.error}').join('\n'), error: true);
  }
}

class _ReceiptDialog extends ConsumerWidget {
  const _ReceiptDialog({required this.sale, required this.store, required this.allowRefund});
  final SaleWithItems sale;
  final StoreInfo store;
  final bool allowRefund;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ReceiptLayout.build(sale, store, width: 42);
    final refunded = sale.sale.status == SaleStatus.refunded.code;
    return AlertDialog(
      title: Text('Chek ${sale.sale.receiptNo}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: ReceiptPreview(lines: lines, width: 42)),
      ),
      actions: [
        if (allowRefund && !refunded)
          TextButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Qaytarish'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => _refund(context, ref),
          ),
        PopupMenuButton<PrintTarget>(
          tooltip: 'Printer tanlash',
          onSelected: (t) => printAndReport(context, ref, sale, target: t, copy: true),
          itemBuilder: (_) => [for (final t in PrintTarget.values) PopupMenuItem(value: t, child: Text(t.label))],
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.print_outlined), SizedBox(width: 6), Text('Printer...')]),
          ),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.print),
          label: const Text('Qayta chop etish'),
          onPressed: () => printAndReport(context, ref, sale, copy: true),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Yopish')),
      ],
    );
  }

  Future<void> _refund(BuildContext context, WidgetRef ref) async {
    final user = ref.read(authProvider)!;
    var admin = user;
    if (UserRole.fromCode(user.role) != UserRole.admin) {
      final a = await requestAdminApproval(context, ref, reason: 'Chekni qaytarish uchun Admin tasdig\'i kerak');
      if (a == null) return;
      admin = a;
    }
    if (!context.mounted) return;
    final ok = await confirmDialog(context, 'Chekni qaytarish',
        'Chek ${sale.sale.receiptNo} to\'liq qaytariladi, tovarlar omborga qaytadi. Davom etilsinmi?',
        ok: 'Qaytarish', danger: true);
    if (!ok) return;
    try {
      await ref.read(checkoutServiceProvider).refund(sale, admin);
      ref.read(syncServiceProvider).requestSync();
      if (context.mounted) {
        Navigator.pop(context);
        showMessage(context, 'Chek qaytarildi');
      }
    } catch (e) {
      if (context.mounted) showMessage(context, e.toString(), error: true);
    }
  }
}

/// Chek maketini "qog'oz" ko'rinishida chizish (monospace shrift).
class ReceiptPreview extends StatelessWidget {
  const ReceiptPreview({super.key, required this.lines, required this.width});
  final List<RLine> lines;
  final int width;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(fontFamily: 'monospace', fontSize: 12.5, color: Colors.black87, height: 1.3);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDF7),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines)
            if (l.isSeparator)
              Text('-' * width, style: base, maxLines: 1, overflow: TextOverflow.clip)
            else
              Text(
                l.text,
                textAlign: switch (l.align) {
                  RAlign.left => TextAlign.left,
                  RAlign.center => TextAlign.center,
                  RAlign.right => TextAlign.right,
                },
                style: base.copyWith(
                  fontWeight: l.bold ? FontWeight.bold : FontWeight.normal,
                  fontSize: l.big ? 17 : 12.5,
                ),
              ),
        ],
      ),
    );
  }
}
