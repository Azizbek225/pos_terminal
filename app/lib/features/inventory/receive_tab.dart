import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/stock_repository.dart';
import '../../services/scanner/barcode_listener.dart';
import '../../state/providers.dart';
import '../pos/widgets/product_search_field.dart';
import '../shell/common_widgets.dart';
import 'product_form_page.dart';

class _ReceiveLine {
  _ReceiveLine(this.product, this.qty, this.cost);
  Product product;
  double qty;
  int cost;
}

/// Kirim hujjati: tovarlarni skanerlab (USB/Bluetooth skaner yoki kamera)
/// ro'yxatga qo'shish, miqdor va kirim narxini kiritish, so'ng bitta tugma bilan
/// omborga qabul qilish. Noma'lum shtrix-kod — yangi tovar kartasini ochadi.
class ReceiveTab extends ConsumerStatefulWidget {
  const ReceiveTab({super.key});

  @override
  ConsumerState<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends ConsumerState<ReceiveTab> with AutomaticKeepAliveClientMixin {
  final _lines = <_ReceiveLine>[];
  final _supplier = TextEditingController();
  final _searchFocus = FocusNode();
  bool _updatePrices = true;
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _supplier.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _add(Product p) {
    setState(() {
      final i = _lines.indexWhere((l) => l.product.id == p.id);
      if (i >= 0) {
        _lines[i].qty += 1;
        final l = _lines.removeAt(i);
        _lines.insert(0, l);
      } else {
        _lines.insert(0, _ReceiveLine(p, 1, p.purchasePrice));
      }
    });
  }

  Future<void> _onCode(String code) async {
    final p = await ref.read(productRepoProvider).findByBarcode(code);
    if (!mounted) return;
    if (p != null) {
      _add(p);
      return;
    }
    final create = await confirmDialog(context, 'Yangi tovar', 'Shtrix-kod $code bazada yo\'q. Yangi tovar yaratilsinmi?',
        ok: 'Yaratish');
    if (!create || !mounted) return;
    final id = await openProductForm(context, barcode: code);
    if (id == null) return;
    final created = await ref.read(productRepoProvider).byId(id);
    if (created != null) _add(created);
  }

  Future<void> _save() async {
    if (_lines.isEmpty) return;
    setState(() => _saving = true);
    try {
      final user = ref.read(authProvider)!;
      final note = _supplier.text.trim().isEmpty ? 'Kirim' : 'Kirim: ${_supplier.text.trim()}';
      final touched = await ref.read(stockRepoProvider).addMovements([
        for (final l in _lines)
          if (l.qty > 0)
            MovementInput(productId: l.product.id, type: MovementType.receipt, qty: l.qty, unitCost: l.cost, note: note),
      ], userId: user.id, userName: user.fullName);

      if (_updatePrices) {
        final repo = ref.read(productRepoProvider);
        for (final l in _lines) {
          if (l.cost > 0 && l.cost != l.product.purchasePrice) {
            await repo.save(ProductsCompanion(
              id: Value(l.product.id),
              purchasePrice: Value(l.cost),
              supplier: _supplier.text.trim().isEmpty ? const Value.absent() : Value(_supplier.text.trim()),
            ));
          }
        }
      }
      await ref.read(alertServiceProvider).checkStock(touched);
      ref.read(syncServiceProvider).requestSync();
      if (mounted) {
        final n = _lines.length;
        setState(_lines.clear);
        showMessage(context, 'Kirim saqlandi: $n ta tovar');
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final total = _lines.fold<int>(0, (s, l) => s + (l.qty * l.cost).round());
    return BarcodeKeyboardListener(
      onBarcode: _onCode,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Tovarni skanerlang yoki qidiring — har bir skanerlash miqdorni 1 ga oshiradi.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          ProductSearchField(focusNode: _searchFocus, onPicked: _add, onNotFound: _onCode, hint: 'Kirim uchun tovar: skaner, nom yoki artikul'),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 300,
              child: TextField(
                controller: _supplier,
                decoration: const InputDecoration(labelText: 'Yetkazib beruvchi / hujjat raqami', isDense: true),
              ),
            ),
            FilterChip(
              label: const Text('Kirim narxini tovar kartasida yangilash'),
              selected: _updatePrices,
              onSelected: (v) => setState(() => _updatePrices = v),
            ),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: Card(
              child: _lines.isEmpty
                  ? const EmptyState(icon: Icons.qr_code_2, text: 'Kirim ro\'yxati bo\'sh')
                  : ListView.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final l = _lines[i];
                        return ListTile(
                          title: Text(l.product.name),
                          subtitle: Text('Joriy qoldiq: ${Fmt.qty(l.product.stockQty)} ${l.product.unit}'
                              ' · ${l.product.barcode}'),
                          trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            ActionChip(
                              label: Text('${Fmt.qty(l.qty)} ${l.product.unit}'),
                              onPressed: () async {
                                final v = await askNumber(context, title: 'Miqdor', initial: l.qty, suffix: l.product.unit);
                                if (v != null) setState(() => l.qty = v);
                              },
                            ),
                            ActionChip(
                              label: Text(Fmt.money(l.cost)),
                              onPressed: () async {
                                final v = await askNumber(context,
                                    title: 'Kirim narxi', initial: l.cost.toDouble(), suffix: "so'm", decimal: false);
                                if (v != null) setState(() => l.cost = v.round());
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() => _lines.removeAt(i)),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text('Pozitsiyalar: ${_lines.length} · Summa: ${Fmt.money(total)}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            OutlinedButton(
              onPressed: _lines.isEmpty ? null : () => setState(_lines.clear),
              child: const Text('Tozalash'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _lines.isEmpty || _saving ? null : _save,
              icon: const Icon(Icons.move_to_inbox),
              label: const Text('Omborga qabul qilish'),
            ),
          ]),
        ]),
      ),
    );
  }
}
