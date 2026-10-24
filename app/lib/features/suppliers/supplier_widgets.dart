import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../services/product_images.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'signature_pad.dart';

/// Qarz summasi rangi: biz qarz — qizil, firma bizga qarz — yashil, nol — oddiy.
Color debtColor(BuildContext context, int debt) {
  final scheme = Theme.of(context).colorScheme;
  if (debt > 0) return scheme.error;
  if (debt < 0) return Colors.green.shade700;
  return scheme.onSurfaceVariant;
}

String debtLabel(int debt) {
  if (debt > 0) return 'Qarz: ${Fmt.money(debt)}';
  if (debt < 0) return 'Firma sizga qarz: ${Fmt.money(-debt)}';
  return "Hisob yopiq";
}

int? _parseMoney(String s) => Fmt.parseNum(s)?.round();

/// Pul kiritish maydoni (1 250 000 ko'rinishida).
class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.onChanged,
    this.autofocus = false,
    this.helper,
  });
  final TextEditingController controller;
  final String label;
  final String? helper;
  final ValueChanged<String>? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))],
    decoration: InputDecoration(labelText: label, suffixText: "so'm", helperText: helper),
    onChanged: onChanged,
  );
}

// ---------------------------------------------------------------------------
//  Firma kartasi (yaratish / tahrirlash)
// ---------------------------------------------------------------------------

/// Qaytaradi: saqlangan firma ID si yoki null.
Future<String?> openSupplierForm(BuildContext context, WidgetRef ref, {Supplier? supplier, String initialName = ''}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SupplierFormDialog(supplier: supplier, initialName: initialName),
  );
}

class _SupplierFormDialog extends ConsumerStatefulWidget {
  const _SupplierFormDialog({this.supplier, this.initialName = ''});
  final Supplier? supplier;
  final String initialName;

  @override
  ConsumerState<_SupplierFormDialog> createState() => _SupplierFormDialogState();
}

class _SupplierFormDialogState extends ConsumerState<_SupplierFormDialog> {
  late final _name = TextEditingController(text: widget.supplier?.name ?? widget.initialName);
  late final _phone = TextEditingController(text: widget.supplier?.phone ?? '');
  late final _contact = TextEditingController(text: widget.supplier?.contactPerson ?? '');
  late final _address = TextEditingController(text: widget.supplier?.address ?? '');
  late final _note = TextEditingController(text: widget.supplier?.note ?? '');
  final _opening = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _contact, _address, _note, _opening]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(supplierRepoProvider);
      final id = await repo.saveSupplier(
        id: widget.supplier?.id,
        name: _name.text,
        phone: _phone.text,
        contactPerson: _contact.text,
        address: _address.text,
        note: _note.text,
      );
      final opening = _parseMoney(_opening.text) ?? 0;
      if (widget.supplier == null && opening > 0) {
        final user = ref.read(authProvider)!;
        await repo.createPurchase(
          supplierId: id,
          lines: const [],
          kind: PurchaseKind.opening,
          total: opening,
          note: "Dasturga kiritilgunga qadar bo'lgan qarz",
          userId: user.id,
          userName: user.fullName,
        );
      }
      ref.read(syncServiceProvider).requestSync();
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) showMessage(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.supplier == null;
    return AlertDialog(
      title: Text(isNew ? 'Yangi firma' : 'Firmani tahrirlash'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                autofocus: isNew && widget.initialName.isEmpty,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Firma nomi *'),
              ),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Telefon'),
              ),
              TextField(
                controller: _contact,
                decoration: const InputDecoration(labelText: 'Agent / vakil ismi'),
              ),
              TextField(
                controller: _address,
                decoration: const InputDecoration(labelText: 'Manzil'),
              ),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Izoh'),
              ),
              if (isNew) ...[
                const SizedBox(height: 8),
                MoneyField(
                  controller: _opening,
                  label: "Boshlang'ich qarz (ixtiyoriy)",
                  helper: 'Firmaga hozirgacha qancha qarzingiz bor',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Saqlash')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  Firma tanlash
// ---------------------------------------------------------------------------

/// Firma tanlash maydoni: bosilganda qidiruvli ro'yxat ochiladi, u yerdan
/// yangi firma ham qo'shish mumkin.
class SupplierPickerField extends ConsumerWidget {
  const SupplierPickerField({super.key, required this.supplierId, required this.onChanged});
  final String? supplierId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(supplierBalancesProvider).value ?? const [];
    final selected = balances.where((b) => b.supplier.id == supplierId).firstOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final id = await pickSupplier(context, ref);
        if (id != null) onChanged(id);
      },
      child: InputDecorator(
        isEmpty: selected == null,
        decoration: InputDecoration(
          labelText: 'Firma (yetkazib beruvchi)',
          isDense: true,
          prefixIcon: const Icon(Icons.business_outlined),
          helperText: selected == null ? null : debtLabel(selected.debt),
          helperStyle: selected == null ? null : TextStyle(color: debtColor(context, selected.debt)),
          suffixIcon: selected == null
              ? const Icon(Icons.arrow_drop_down)
              : IconButton(tooltip: 'Firmasiz', icon: const Icon(Icons.close), onPressed: () => onChanged(null)),
        ),
        child: Text(selected?.supplier.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// Qaytaradi: tanlangan (yoki yangi yaratilgan) firma ID si.
Future<String?> pickSupplier(BuildContext context, WidgetRef ref) {
  return showDialog<String>(context: context, builder: (_) => const _SupplierPickDialog());
}

class _SupplierPickDialog extends ConsumerStatefulWidget {
  const _SupplierPickDialog();

  @override
  ConsumerState<_SupplierPickDialog> createState() => _SupplierPickDialogState();
}

class _SupplierPickDialogState extends ConsumerState<_SupplierPickDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(supplierBalancesProvider).value ?? const [];
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? all
        : all.where((b) => b.supplier.name.toLowerCase().contains(q) || b.supplier.phone.contains(q)).toList();
    return AlertDialog(
      title: const Text('Firmani tanlang'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Qidirish', isDense: true),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? EmptyState(
                      icon: Icons.business_outlined,
                      text: all.isEmpty ? "Hali firma qo'shilmagan" : 'Topilmadi',
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final b = list[i];
                        return ListTile(
                          leading: const Icon(Icons.business_outlined),
                          title: Text(b.supplier.name),
                          subtitle: Text(debtLabel(b.debt), style: TextStyle(color: debtColor(context, b.debt))),
                          onTap: () => Navigator.pop(context, b.supplier.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Yangi firma'),
          onPressed: () async {
            final id = await openSupplierForm(context, ref, initialName: _q.trim());
            if (id != null && context.mounted) Navigator.pop(context, id);
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  To'lov dialogi
// ---------------------------------------------------------------------------

/// Pulni olgan agent: ismi va ekranga chizilgan imzosi.
class SignatureField extends StatelessWidget {
  const SignatureField({
    super.key,
    required this.name,
    required this.signature,
    required this.onSigned,
    this.label = 'Pulni olgan agent',
    this.subtitle,
  });
  final TextEditingController name;
  final String signature;
  final ValueChanged<String> onSigned;
  final String label;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: '$label (ismi)', prefixIcon: const Icon(Icons.person_outline)),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (signature.isNotEmpty) ...[
              InkWell(
                onTap: () => openPhotoViewer(context, [signature]),
                child: Container(
                  height: 56,
                  width: 120,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  ),
                  child: SignatureImage(name: signature),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final n = await openSignaturePad(
                    context,
                    title: name.text.trim().isEmpty ? 'Agent imzosi' : '${name.text.trim()} imzosi',
                    subtitle: subtitle,
                  );
                  if (n != null) onSigned(n);
                },
                icon: Icon(signature.isEmpty ? Icons.draw_outlined : Icons.edit),
                label: Text(signature.isEmpty ? "Imzo qo'ydirish" : 'Qayta imzolash'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Saqlangan imzo rasmi (oq fon). Fayl hali bu qurilmada bo'lmasa — belgi.
class SignatureImage extends StatelessWidget {
  const SignatureImage({super.key, required this.name, this.height});
  final String name;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final image = ProductImages.provider(name);
    if (image == null) return const Center(child: Icon(Icons.cloud_download_outlined, color: Colors.black38));
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Image(image: image, height: height, fit: BoxFit.contain, key: ValueKey(name)),
    );
  }
}

/// Firmaga to'lov (qarzni uzish) yoki firmadan pul qaytishi. Qaytaradi: saqlandimi.
Future<bool> openPaymentDialog(
  BuildContext context,
  WidgetRef ref, {
  required Supplier supplier,
  required int debt,
  String? purchaseId,
  int? suggested,
  bool refund = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _PaymentDialog(supplier: supplier, debt: debt, purchaseId: purchaseId, suggested: suggested, refund: refund),
  );
  return r ?? false;
}

class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({
    required this.supplier,
    required this.debt,
    this.purchaseId,
    this.suggested,
    this.refund = false,
  });
  final Supplier supplier;
  final int debt;
  final String? purchaseId;
  final int? suggested;
  final bool refund;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  late bool _refund = widget.refund;
  late final _amount = TextEditingController(text: _initialAmount());
  final _note = TextEditingController();
  late final _agent = TextEditingController(text: widget.supplier.contactPerson);
  String _signature = '';
  PaymentType _method = PaymentType.cash;
  DateTime _date = DateTime.now();
  bool _saving = false;

  String _initialAmount() {
    final v = widget.suggested ?? (_refund ? -widget.debt : widget.debt);
    return v > 0 ? Fmt.money(v, suffix: false) : '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _agent.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = _parseMoney(_amount.text) ?? 0;
    if (amount <= 0) {
      showMessage(context, 'Summani kiriting', error: true);
      return;
    }
    if (!_refund && _signature.isEmpty) {
      final ok = await confirmDialog(
        context,
        "Imzosiz to'lov",
        "Agent imzo qo'ymadi. Imzosiz saqlansinmi?",
        ok: 'Imzosiz saqlash',
        cancel: 'Orqaga',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      final user = ref.read(authProvider)!;
      final now = DateTime.now();
      final at = DayRange.startOfDay(_date) == DayRange.startOfDay(now)
          ? now
          : DateTime(_date.year, _date.month, _date.day, 12);
      await ref
          .read(supplierRepoProvider)
          .addPayment(
            supplierId: widget.supplier.id,
            amount: amount,
            refund: _refund,
            method: _method,
            purchaseId: widget.purchaseId,
            paidAt: at.millisecondsSinceEpoch,
            note: _note.text,
            receivedBy: _agent.text,
            signaturePath: _signature,
            userId: user.id,
            userName: user.fullName,
          );
      ref.read(syncServiceProvider).requestSync();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cash = ref.watch(todaySummaryProvider).value?.cash;
    final amount = _parseMoney(_amount.text) ?? 0;
    final after = _refund ? widget.debt + amount : widget.debt - amount;
    return AlertDialog(
      title: Text(widget.supplier.name),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                debtLabel(widget.debt),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: debtColor(context, widget.debt),
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.north_east), label: Text("Firmaga to'lash")),
                  ButtonSegment(value: true, icon: Icon(Icons.south_west), label: Text('Firmadan olish')),
                ],
                selected: {_refund},
                onSelectionChanged: (v) => setState(() {
                  _refund = v.first;
                  _amount.text = _initialAmount();
                }),
              ),
              const SizedBox(height: 8),
              MoneyField(
                controller: _amount,
                label: _refund ? 'Firma qaytargan summa' : "To'lanadigan summa",
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
              if (cash != null && !_refund)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Bugungi naqd tushum: ${Fmt.money(cash)}', style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in [PaymentType.cash, PaymentType.card, PaymentType.transfer])
                    ChoiceChip(
                      label: Text(m.label),
                      selected: _method == m,
                      onSelected: (_) => setState(() => _method = m),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text('Sana: ${Fmt.date(_date)}'),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (d != null) setState(() => _date = d);
                },
              ),
              SignatureField(
                name: _agent,
                signature: _signature,
                label: _refund ? 'Pulni bergan agent' : 'Pulni olgan agent',
                subtitle: '${_refund ? 'Qaytarildi' : 'Qabul qilindi'}: ${Fmt.money(amount)}\n${widget.supplier.name}',
                onSigned: (n) => setState(() => _signature = n),
              ),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Izoh (ixtiyoriy)'),
              ),
              const SizedBox(height: 12),
              Text(
                'Keyin — ${debtLabel(after)}',
                style: TextStyle(color: debtColor(context, after), fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Bekor qilish')),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.payments_outlined),
          label: Text(_refund ? 'Saqlash' : "To'lash"),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  Kam kelgan / qaytarilgan tovar (qarzni kamaytiradi)
// ---------------------------------------------------------------------------

/// Summa bo'yicha: masalan prays-listdagi tovarlarning bir qismi kelmadi.
/// Qaytaradi: hujjat yaratildimi.
Future<bool> openCreditDialog(
  BuildContext context,
  WidgetRef ref, {
  required Supplier supplier,
  required int debt,
}) async {
  final amount = TextEditingController();
  final note = TextEditingController();
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final v = _parseMoney(amount.text) ?? 0;
        return AlertDialog(
          title: const Text('Kam kelgan / qaytarilgan tovar'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Prays-listdagi tovar kelmagan, kam kelgan yoki firmaga qaytarilgan bo'lsa — shu summa "
                  "qarzdan ayriladi. Qarz minusga o'tsa, firma sizga qarz bo'ladi.",
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  debtLabel(debt),
                  style: TextStyle(color: debtColor(c, debt), fontWeight: FontWeight.bold),
                ),
                MoneyField(controller: amount, label: 'Summa', autofocus: true, onChanged: (_) => setState(() {})),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Sabab (masalan: 5 ta shampun kelmadi)'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Keyin — ${debtLabel(debt - v)}',
                  style: TextStyle(color: debtColor(c, debt - v), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Bekor qilish')),
            FilledButton(onPressed: v > 0 ? () => Navigator.pop(c, true) : null, child: const Text('Saqlash')),
          ],
        );
      },
    ),
  );
  final value = _parseMoney(amount.text) ?? 0;
  final reason = note.text;
  amount.dispose();
  note.dispose();
  if (r != true || value <= 0) return false;
  final user = ref.read(authProvider)!;
  await ref
      .read(supplierRepoProvider)
      .createCredit(supplierId: supplier.id, amount: value, note: reason, userId: user.id, userName: user.fullName);
  ref.read(syncServiceProvider).requestSync();
  return true;
}

// ---------------------------------------------------------------------------
//  Prays-list suratlari
// ---------------------------------------------------------------------------

/// Prays-list / nakladnoy suratini olish (katta o'lchamda — matn o'qilsin).
Future<String?> pickDocumentPhoto(BuildContext context, {required bool camera}) async {
  try {
    return await ProductImages.pick(context, camera: camera, maxSize: 2200, title: 'Prays-listni suratga olish');
  } catch (e) {
    if (context.mounted) showMessage(context, 'Surat olinmadi: $e', error: true);
    return null;
  }
}

/// Suratlar qatori: kichik ko'rinishlar + qo'shish tugmalari.
class DocumentPhotosStrip extends StatelessWidget {
  const DocumentPhotosStrip({super.key, required this.names, this.onAdd, this.onRemove, this.size = 72});
  final List<String> names;
  final void Function(bool camera)? onAdd;
  final ValueChanged<String>? onRemove;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < names.length; i++)
          Stack(
            clipBehavior: Clip.none,
            children: [
              InkWell(
                onTap: () => openPhotoViewer(context, names, initial: i),
                child: ProductThumb(
                  imagePath: names[i],
                  size: size,
                  fallback: Container(
                    width: size,
                    height: size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.cloud_download_outlined),
                  ),
                ),
              ),
              if (onRemove != null)
                Positioned(
                  right: -8,
                  top: -8,
                  child: IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    tooltip: "O'chirish",
                    icon: const Icon(Icons.close),
                    onPressed: () => onRemove!(names[i]),
                  ),
                ),
            ],
          ),
        if (onAdd != null) ...[
          if (ProductImages.cameraSupported)
            OutlinedButton.icon(
              onPressed: () => onAdd!(true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(names.isEmpty ? 'Prays-listni suratga olish' : 'Yana surat'),
            ),
          OutlinedButton.icon(
            onPressed: () => onAdd!(false),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(ProductImages.cameraSupported && !Platform.isWindows ? 'Galereyadan' : 'Fayldan'),
          ),
        ],
      ],
    );
  }
}

/// Suratlarni to'liq ekranda ko'rish (kattalashtirish mumkin).
Future<void> openPhotoViewer(BuildContext context, List<String> names, {int initial = 0}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PhotoViewer(names: names, initial: initial),
    ),
  );
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.names, required this.initial});
  final List<String> names;
  final int initial;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final _pc = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Surat ${_i + 1} / ${widget.names.length}'),
      ),
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.names.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) {
          final image = ProductImages.provider(widget.names[i]);
          if (image == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Surat hali bu qurilmaga yuklanmagan. Sinxronlashdan keyin ko\'rinadi.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            );
          }
          return InteractiveViewer(maxScale: 6, child: Center(child: Image(image: image)));
        },
      ),
    );
  }
}
