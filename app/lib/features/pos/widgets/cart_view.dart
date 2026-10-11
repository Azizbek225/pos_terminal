import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters.dart';
import '../../../state/cart.dart';
import '../../../state/providers.dart';
import '../../shell/common_widgets.dart';

/// Savat: tovar qatorlari, miqdorni o'zgartirish va o'chirish.
class CartView extends ConsumerWidget {
  const CartView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    if (cart.isEmpty) {
      return const EmptyState(
        icon: Icons.shopping_cart_outlined,
        text: "Savat bo'sh.\nTovarni skanerlang yoki qidiruvdan tanlang.",
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: cart.lines.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _CartLineTile(line: cart.lines[i], index: cart.lines.length - i),
    );
  }
}

class _CartLineTile extends ConsumerWidget {
  const _CartLineTile({required this.line, required this.index});
  final CartLine line;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = line.product;
    final notifier = ref.read(cartProvider.notifier);
    final overStock = line.qty > p.stockQty;
    final step = p.isWeighted ? 0.1 : 1.0;

    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(p.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      Text(
        '${Fmt.money(p.salePrice)} / ${p.unit}'
        '${p.barcode.isNotEmpty ? '  ·  ${p.barcode}' : ''}',
        style: theme.textTheme.bodySmall,
      ),
      if (overStock)
        Text('Omborda: ${Fmt.qty(p.stockQty)} ${p.unit}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
    ]);
    final qtyControls = Row(mainAxisSize: MainAxisSize.min, children: [
      _RoundButton(icon: Icons.remove, onTap: () => notifier.decrement(p.id, step)),
      InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final v = await askNumber(context, title: 'Miqdor — ${p.name}', initial: line.qty, suffix: p.unit);
          if (v != null) notifier.setQty(p.id, v);
        },
        child: Container(
          constraints: const BoxConstraints(minWidth: 52),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          alignment: Alignment.center,
          child: Text(Fmt.qty(line.qty), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ),
      ),
      _RoundButton(icon: Icons.add, onTap: () => notifier.increment(p.id, step)),
    ]);
    final total = Text(
      Fmt.money(line.gross),
      textAlign: TextAlign.right,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    );
    final delete = IconButton(
      tooltip: "O'chirish",
      icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
      onPressed: () => notifier.remove(p.id),
    );

    return LayoutBuilder(builder: (context, c) {
      // Tor ekran (telefon): ikki qatorli ko'rinish.
      if (c.maxWidth < 560) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Column(children: [
            Row(children: [Expanded(child: info), delete]),
            Row(children: [qtyControls, const Spacer(), total, const SizedBox(width: 12)]),
          ]),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          SizedBox(width: 28, child: Text('$index', style: theme.textTheme.bodySmall, textAlign: TextAlign.center)),
          Expanded(child: info),
          qtyControls,
          SizedBox(width: 130, child: total),
          delete,
        ]),
      );
    });
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton.filledTonal(onPressed: onTap, icon: Icon(icon, size: 20)),
    );
  }
}
