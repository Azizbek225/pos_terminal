import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/stock_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

/// Bitta tovar bo'yicha ombor harakati: kirim, chiqim (hisobdan chiqarish),
/// yetkazib beruvchiga qaytarish, mijoz qaytargan tovar, inventarizatsiya.
Future<void> showStockMovementDialog(BuildContext context, WidgetRef ref, Product p) {
  return showDialog<void>(context: context, builder: (_) => _MovementDialog(product: p));
}

class _MovementDialog extends ConsumerStatefulWidget {
  const _MovementDialog({required this.product});
  final Product product;

  @override
  ConsumerState<_MovementDialog> createState() => _MovementDialogState();
}

class _MovementDialogState extends ConsumerState<_MovementDialog> {
  MovementType _type = MovementType.writeOff;
  final _qty = TextEditingController();
  final _note = TextEditingController();
  String? _error;

  static const _types = [
    MovementType.receipt,
    MovementType.writeOff,
    MovementType.supplierReturn,
    MovementType.customerReturn,
    MovementType.adjustment,
  ];

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final p = widget.product;
    final v = Fmt.parseNum(_qty.text);
    if (v == null || (v <= 0 && _type != MovementType.adjustment) || v < 0) {
      setState(() => _error = "Miqdorni to'g'ri kiriting");
      return;
    }
    if ((_type == MovementType.writeOff || _type == MovementType.supplierReturn) && _note.text.trim().isEmpty) {
      setState(() => _error = 'Sababni kiriting (masalan: singan, muddati o\'tgan)');
      return;
    }
    // Inventarizatsiyada foydalanuvchi haqiqiy sanalgan qoldiqni kiritadi.
    final delta = _type == MovementType.adjustment ? v - p.stockQty : v * _type.sign;
    if (delta == 0) {
      Navigator.pop(context);
      return;
    }
    final user = ref.read(authProvider)!;
    final touched = await ref.read(stockRepoProvider).addMovements([
      MovementInput(
        productId: p.id,
        type: _type,
        qty: delta,
        unitCost: p.purchasePrice,
        note: _note.text.trim(),
      ),
    ], userId: user.id, userName: user.fullName);
    await ref.read(alertServiceProvider).checkStock(touched);
    ref.read(syncServiceProvider).requestSync();
    if (mounted) {
      Navigator.pop(context);
      showMessage(context, '${_type.label}: ${Fmt.qty(delta)} ${p.unit} — ${p.name}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return AlertDialog(
      title: Text(p.name),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Joriy qoldiq: ${Fmt.qty(p.stockQty)} ${p.unit}', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          DropdownButtonFormField<MovementType>(
            isExpanded: true,
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Harakat turi'),
            items: [for (final t in _types) DropdownMenuItem(value: t, child: Text(t.label))],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _type == MovementType.adjustment ? 'Haqiqiy (sanalgan) qoldiq' : 'Miqdor',
              suffixText: p.unit,
            ),
          ),
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Izoh / sabab')),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton(onPressed: _save, child: const Text('Saqlash')),
      ],
    );
  }
}
