import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/stock_repository.dart';
import '../../data/repositories/supplier_repository.dart';
import '../../services/scanner/barcode_listener.dart';
import '../../state/providers.dart';
import '../pos/widgets/product_search_field.dart';
import '../shell/common_widgets.dart';
import '../suppliers/supplier_widgets.dart';
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
  final _docNo = TextEditingController();
  final _searchFocus = FocusNode();
  String? _supplierId;
  DateTime _docDate = DateTime.now();
  List<String> _photos = [];
  bool _updatePrices = true;
  bool _saving = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _docNo.dispose();
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
    final create = await confirmDialog(
      context,
      'Yangi tovar',
      'Shtrix-kod $code bazada yo\'q. Yangi tovar yaratilsinmi?',
      ok: 'Yaratish',
    );
    if (!create || !mounted) return;
    final id = await openProductForm(context, barcode: code);
    if (id == null) return;
    final created = await ref.read(productRepoProvider).byId(id);
    if (created != null) _add(created);
  }

  Future<void> _addPhoto(bool camera) async {
    final name = await pickDocumentPhoto(context, camera: camera);
    if (name != null && mounted) setState(() => _photos = [..._photos, name]);
  }

  Future<void> _save() async {
    if (_lines.isEmpty) return;
    final total = _lines.fold<int>(0, (s, l) => s + (l.qty * l.cost).round());
    final supplier = _supplierId == null ? null : await ref.read(supplierRepoProvider).byId(_supplierId!);
    ({int paid, PaymentType method, String agent, String signature})? pay;
    if (supplier != null) {
      final debt = await ref.read(supplierRepoProvider).balanceOf(supplier.id);
      if (!mounted) return;
      pay = await showDialog<({int paid, PaymentType method, String agent, String signature})>(
        context: context,
        builder: (_) => _ReceivePaymentDialog(supplierName: supplier.name, total: total, debtBefore: debt),
      );
      if (pay == null) return;
    }
    setState(() => _saving = true);
    try {
      final user = ref.read(authProvider)!;
      final doc = _docNo.text.trim();
      final now = DateTime.now();
      final docDate = DayRange.startOfDay(_docDate) == DayRange.startOfDay(now)
          ? now
          : DateTime(_docDate.year, _docDate.month, _docDate.day, 12);
      String? purchaseId;
      if (supplier != null) {
        purchaseId = await ref
            .read(supplierRepoProvider)
            .createPurchase(
              supplierId: supplier.id,
              lines: [
                for (final l in _lines)
                  if (l.qty > 0)
                    PurchaseLineInput(
                      productId: l.product.id,
                      productName: l.product.name,
                      barcode: l.product.barcode,
                      unit: l.product.unit,
                      qty: l.qty,
                      price: l.cost,
                    ),
              ],
              docNo: doc,
              docDate: docDate.millisecondsSinceEpoch,
              imagePaths: _photos,
              paidNow: pay!.paid,
              method: pay.method,
              receivedBy: pay.agent,
              signaturePath: pay.signature,
              userId: user.id,
              userName: user.fullName,
            );
      }
      final note = supplier == null
          ? (doc.isEmpty ? 'Kirim' : 'Kirim №$doc')
          : 'Kirim: ${supplier.name}${doc.isEmpty ? '' : ' №$doc'}';
      final touched = await ref
          .read(stockRepoProvider)
          .addMovements(
            [
              for (final l in _lines)
                if (l.qty > 0)
                  MovementInput(
                    productId: l.product.id,
                    type: MovementType.receipt,
                    qty: l.qty,
                    unitCost: l.cost,
                    note: note,
                    refId: purchaseId,
                  ),
            ],
            userId: user.id,
            userName: user.fullName,
          );

      if (_updatePrices) {
        final repo = ref.read(productRepoProvider);
        for (final l in _lines) {
          if (l.cost > 0 && l.cost != l.product.purchasePrice) {
            await repo.save(
              ProductsCompanion(
                id: Value(l.product.id),
                purchasePrice: Value(l.cost),
                supplier: supplier == null ? const Value.absent() : Value(supplier.name),
              ),
            );
          }
        }
      }
      await ref.read(alertServiceProvider).checkStock(touched);
      ref.read(syncServiceProvider).requestSync();
      if (mounted) {
        final n = _lines.length;
        setState(() {
          _lines.clear();
          _photos = [];
          _docNo.clear();
          _docDate = DateTime.now();
        });
        final debtPart = supplier == null || pay == null || pay.paid >= total
            ? ''
            : ' · qarzga yozildi: ${Fmt.money(total - pay.paid)}';
        showMessage(context, 'Kirim saqlandi: $n ta tovar$debtPart');
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _lineChips(_ReceiveLine l, int i) => Wrap(
    spacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
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
          final v = await askNumber(
            context,
            title: 'Kirim narxi',
            initial: l.cost.toDouble(),
            suffix: "so'm",
            decimal: false,
          );
          if (v != null) setState(() => l.cost = v.round());
        },
      ),
      IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _lines.removeAt(i))),
    ],
  );

  Widget _lineTile(int i, {required bool narrow}) {
    final l = _lines[i];
    final info = 'Joriy qoldiq: ${Fmt.qty(l.product.stockQty)} ${l.product.unit} · ${l.product.barcode}';
    if (narrow) {
      // Telefonda tugmalar nom ostida: tor ekranda nom siqilib qolmasin.
      return ListTile(
        title: Text(l.product.name),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(info), _lineChips(l, i)]),
      );
    }
    return ListTile(title: Text(l.product.name), subtitle: Text(info), trailing: _lineChips(l, i));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final total = _lines.fold<int>(0, (s, l) => s + (l.qty * l.cost).round());
    final narrow = MediaQuery.sizeOf(context).width < 600;

    final header = <Widget>[
      Text(
        'Tovarni skanerlang yoki qidiring — har bir skanerlash miqdorni 1 ga oshiradi.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 8),
      ProductSearchField(
        focusNode: _searchFocus,
        onPicked: _add,
        onNotFound: _onCode,
        hint: 'Kirim uchun tovar: skaner, nom yoki artikul',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: narrow ? double.infinity : 320,
            child: SupplierPickerField(supplierId: _supplierId, onChanged: (v) => setState(() => _supplierId = v)),
          ),
          SizedBox(
            width: narrow ? double.infinity : 180,
            child: TextField(
              controller: _docNo,
              decoration: const InputDecoration(labelText: 'Nakladnoy raqami', isDense: true),
            ),
          ),
          ActionChip(
            avatar: const Icon(Icons.event, size: 18),
            label: Text('Sana: ${Fmt.date(_docDate)}'),
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _docDate,
                firstDate: DateTime(2020),
                lastDate: DateTime.now(),
              );
              if (d != null) setState(() => _docDate = d);
            },
          ),
          FilterChip(
            label: const Text('Kirim narxini tovar kartasida yangilash'),
            selected: _updatePrices,
            onSelected: (v) => setState(() => _updatePrices = v),
          ),
        ],
      ),
      if (_supplierId != null) ...[
        const SizedBox(height: 8),
        DocumentPhotosStrip(
          names: _photos,
          size: 56,
          onAdd: _addPhoto,
          onRemove: (n) => setState(() => _photos = _photos.where((x) => x != n).toList()),
        ),
      ],
      const SizedBox(height: 8),
    ];

    final summary = Text(
      'Pozitsiyalar: ${_lines.length} · Summa: ${Fmt.money(total)}',
      style: Theme.of(context).textTheme.titleMedium,
    );
    final clearButton = OutlinedButton(
      onPressed: _lines.isEmpty ? null : () => setState(_lines.clear),
      child: const Text('Tozalash'),
    );
    final saveButton = FilledButton.icon(
      onPressed: _lines.isEmpty || _saving ? null : _save,
      icon: const Icon(Icons.move_to_inbox),
      label: const Text('Omborga qabul qilish'),
    );

    if (narrow) {
      // Telefon: sarlavha va ro'yxat birga aylanadi, tugmalar esa pastda doim
      // ko'rinadi (klaviatura ochilganda ham, ekran past bo'lsa ham).
      return BarcodeKeyboardListener(
        onBarcode: _onCode,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                children: [
                  ...header,
                  if (_lines.isEmpty)
                    const SizedBox(
                      height: 160,
                      child: EmptyState(icon: Icons.qr_code_2, text: 'Kirim ro\'yxati bo\'sh'),
                    )
                  else
                    Card(
                      child: Column(
                        children: [
                          for (var i = 0; i < _lines.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _lineTile(i, narrow: true),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Material(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    summary,
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        clearButton,
                        const SizedBox(width: 8),
                        Expanded(child: saveButton),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return BarcodeKeyboardListener(
      onBarcode: _onCode,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...header,
            Expanded(
              child: Card(
                child: _lines.isEmpty
                    ? const EmptyState(icon: Icons.qr_code_2, text: 'Kirim ro\'yxati bo\'sh')
                    : ListView.separated(
                        itemCount: _lines.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) => _lineTile(i, narrow: false),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: summary),
                clearButton,
                const SizedBox(width: 8),
                saveButton,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Kirimni saqlashdan oldin: firmaga hozir qancha to'lanadi, qolgani qarzga.
class _ReceivePaymentDialog extends StatefulWidget {
  const _ReceivePaymentDialog({required this.supplierName, required this.total, required this.debtBefore});
  final String supplierName;
  final int total;
  final int debtBefore;

  @override
  State<_ReceivePaymentDialog> createState() => _ReceivePaymentDialogState();
}

class _ReceivePaymentDialogState extends State<_ReceivePaymentDialog> {
  final _paid = TextEditingController();
  final _agent = TextEditingController();
  String _signature = '';
  PaymentType _method = PaymentType.cash;

  int get _amount => (Fmt.parseNum(_paid.text) ?? 0).round();

  @override
  void dispose() {
    _paid.dispose();
    _agent.dispose();
    super.dispose();
  }

  void _set(int v) => setState(() => _paid.text = v == 0 ? '' : Fmt.money(v, suffix: false));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paid = _amount;
    final toDebt = widget.total - paid;
    final after = widget.debtBefore + toDebt;
    return AlertDialog(
      title: Text('Kirim: ${widget.supplierName}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Kirim summasi: ${Fmt.money(widget.total)}',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (widget.debtBefore != 0) Text('Oldingi holat — ${debtLabel(widget.debtBefore)}'),
              const SizedBox(height: 12),
              MoneyField(
                controller: _paid,
                label: "Hozir to'lanadi",
                autofocus: true,
                helper: "Kassada borini kiriting, qolgani qarzga yoziladi",
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ActionChip(label: const Text("To'liq"), onPressed: () => _set(widget.total)),
                  ActionChip(label: const Text('Hammasi qarzga'), onPressed: () => _set(0)),
                  for (final m in [PaymentType.cash, PaymentType.card, PaymentType.transfer])
                    ChoiceChip(
                      label: Text(m.label),
                      selected: _method == m,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (toDebt > 0)
                Text(
                  'Qarzga yoziladi: ${Fmt.money(toDebt)}',
                  style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold),
                ),
              if (toDebt < 0)
                Text(
                  'Ortiqcha ${Fmt.money(-toDebt)} avans (yoki eski qarzga) hisoblanadi',
                  style: TextStyle(color: Colors.green.shade700),
                ),
              Text('Firma bilan yangi holat — ${debtLabel(after)}', style: TextStyle(color: debtColor(context, after))),
              if (paid > 0) ...[
                const SizedBox(height: 12),
                SignatureField(
                  name: _agent,
                  signature: _signature,
                  subtitle: 'Qabul qilindi: ${Fmt.money(paid)}\n${widget.supplierName}',
                  onSigned: (n) => setState(() => _signature = n),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton.icon(
          onPressed: paid < 0
              ? null
              : () => Navigator.pop(context, (
                  paid: paid,
                  method: _method,
                  agent: _agent.text,
                  signature: paid > 0 ? _signature : '',
                )),
          icon: const Icon(Icons.move_to_inbox),
          label: const Text('Saqlash'),
        ),
      ],
    );
  }
}
