import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants.dart';
import '../../../core/formatters.dart';
import '../../../data/database.dart';
import '../../../state/cart.dart';
import '../../../state/providers.dart';
import 'admin_approval_dialog.dart';

/// Chegirma belgilash: foiz (1–20% kassir uchun) yoki summa.
/// 20% dan yuqori chegirma faqat Admin tomonidan (yoki Admin tasdig'i bilan) beriladi.
Future<void> showDiscountDialog(BuildContext context, WidgetRef ref) async {
  final cart = ref.read(cartProvider);
  if (cart.isEmpty) return;
  await showDialog<void>(context: context, builder: (_) => const _DiscountDialog());
}

class _DiscountDialog extends ConsumerStatefulWidget {
  const _DiscountDialog();

  @override
  ConsumerState<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends ConsumerState<_DiscountDialog> {
  late DiscountType _type;
  late final TextEditingController _value;
  String? _error;

  static const _quick = [1.0, 3.0, 5.0, 7.0, 10.0, 15.0, 20.0];

  @override
  void initState() {
    super.initState();
    final c = ref.read(cartProvider);
    _type = c.discountType == DiscountType.none ? DiscountType.percent : c.discountType;
    _value = TextEditingController(text: c.discountValue > 0 ? Fmt.qty(c.discountValue).replaceAll(' ', '') : '');
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  double get _parsed => Fmt.parseNum(_value.text) ?? 0;

  /// Kiritilgan chegirmaning foizdagi ekvivalenti.
  double _percentOf(int subtotal) {
    if (subtotal == 0) return 0;
    return _type == DiscountType.percent ? _parsed : _parsed * 100 / subtotal;
  }

  Future<void> _apply() async {
    final cart = ref.read(cartProvider);
    final user = ref.read(authProvider)!;
    final v = _parsed;
    if (v <= 0) {
      ref.read(cartProvider.notifier).clearDiscount();
      Navigator.pop(context);
      return;
    }
    final pct = _percentOf(cart.subtotal);
    if (pct > kAbsoluteMaxDiscountPercent) {
      setState(() => _error = 'Chegirma chek summasidan oshmasligi kerak');
      return;
    }
    User? approvedBy;
    final isAdmin = ref.read(currentRoleProvider) == UserRole.admin;
    if (pct > kCashierMaxDiscountPercent && !isAdmin) {
      approvedBy = await requestAdminApproval(
        context,
        ref,
        reason: '${pct.toStringAsFixed(1)}% chegirma — 20% dan yuqori chegirmani faqat Admin tasdiqlaydi.',
      );
      if (approvedBy == null) return;
    }
    ref.read(cartProvider.notifier).setDiscount(_type, v, approvedBy: approvedBy ?? (isAdmin && pct > 20 ? user : null));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final pct = _percentOf(cart.subtotal);
    final amount = _type == DiscountType.percent ? (cart.subtotal * _parsed / 100).round() : _parsed.round();
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Chegirma'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<DiscountType>(
            segments: const [
              ButtonSegment(value: DiscountType.percent, label: Text('Foiz %'), icon: Icon(Icons.percent)),
              ButtonSegment(value: DiscountType.amount, label: Text('Summa'), icon: Icon(Icons.payments)),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() {
              _type = s.first;
              _value.clear();
            }),
          ),
          const SizedBox(height: 14),
          if (_type == DiscountType.percent)
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final q in _quick)
                ChoiceChip(
                  label: Text('${q.toInt()}%'),
                  selected: _parsed == q,
                  onSelected: (_) => setState(() => _value.text = q.toInt().toString()),
                ),
            ]),
          const SizedBox(height: 14),
          TextField(
            controller: _value,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _type == DiscountType.percent ? 'Foiz' : 'Summa',
              suffixText: _type == DiscountType.percent ? '%' : "so'm",
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 12),
          Text('Chek: ${Fmt.money(cart.subtotal)}'),
          Text('Chegirma: ${Fmt.money(amount.clamp(0, cart.subtotal))}  (${pct.toStringAsFixed(1)}%)',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('To\'lanadi: ${Fmt.money((cart.subtotal - amount).clamp(0, cart.subtotal))}'),
          if (pct > kCashierMaxDiscountPercent)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('20% dan yuqori — Admin tasdig\'i talab qilinadi',
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            ref.read(cartProvider.notifier).clearDiscount();
            Navigator.pop(context);
          },
          child: const Text('Chegirmani olib tashlash'),
        ),
        FilledButton(onPressed: _apply, child: const Text("Qo'llash")),
      ],
    );
  }
}
