import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../services/printing/label_pdf.dart';
import '../../services/printing/printer_config.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

/// Yorliq chop etish faqat kompyuterda (tizim printeri orqali).
bool get labelPrintSupported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

const _kSize = 'label.size';
const _kKind = 'label.kind';
const _kName = 'label.showName';
const _kPrice = 'label.showPrice';
const _kTarget = 'label.printer'; // 1 | 2 | 0 (tizim oynasi)

/// Tovar uchun shtrix/QR-kodli yorliqlarni chop etish oynasi.
Future<void> showLabelPrintDialog(BuildContext context, LabelData data) =>
    showDialog<void>(context: context, builder: (_) => _LabelPrintDialog(data));

class _LabelPrintDialog extends ConsumerStatefulWidget {
  const _LabelPrintDialog(this.data);
  final LabelData data;

  @override
  ConsumerState<_LabelPrintDialog> createState() => _LabelPrintDialogState();
}

class _LabelPrintDialogState extends ConsumerState<_LabelPrintDialog> {
  final _count = TextEditingController(text: '1');
  LabelSize _size = LabelSize.s58x40;
  LabelCodeKind _kind = LabelCodeKind.barcode;
  bool _showName = true;
  bool _showPrice = true;
  bool _printing = false;

  /// 1 yoki 2 — sozlamalardagi printer; 0 — Windows chop etish oynasida tanlash.
  int _target = 2;
  final _configs = <int, PrinterConfig>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(settingsRepoProvider);
    final size = await s.get(_kSize), kind = await s.get(_kKind);
    final name = await s.get(_kName), price = await s.get(_kPrice);
    final target = int.tryParse(await s.get(_kTarget) ?? '');
    final printers = ref.read(printerServiceProvider);
    final c1 = await printers.config(1), c2 = await printers.config(2);
    if (!mounted) return;
    setState(() {
      _configs
        ..[1] = c1
        ..[2] = c2;
      _target = target ?? 2;
      _size = LabelSize.fromCode(size);
      _kind = LabelCodeKind.fromCode(kind);
      _showName = name != '0';
      _showPrice = price != '0';
    });
  }

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  int get _n => int.tryParse(_count.text.trim()) ?? 0;

  /// USB/tizim printeri yoki Windows oynasi — PDF (o'lcham tanlanadi);
  /// tarmoq/Bluetooth termoprinter — ESC/POS (qog'oz kengligi printerniki).
  bool get _usesPdf {
    if (_target == 0) return true;
    final c = _configs[_target];
    return c == null || (c.connection == PrinterConnection.system && !c.address.startsWith('/dev/'));
  }

  String _printerTitle(int slot) {
    final c = _configs[slot];
    if (c == null || !c.enabled) return '$slot-printer (sozlanmagan)';
    return '$slot-printer: ${c.name.isEmpty ? c.address : c.name}';
  }

  bool get _ready => _target == 0 || (_configs[_target]?.enabled ?? false);

  Future<void> _print() async {
    final n = _n;
    if (n < 1 || n > 1000) {
      showMessage(context, 'Soni 1 dan 1000 gacha bo\'lishi kerak', error: true);
      return;
    }
    setState(() => _printing = true);
    try {
      await ref.read(settingsRepoProvider).setAll({
        _kSize: _size.code,
        _kKind: _kind.code,
        _kName: _showName ? '1' : '0',
        _kPrice: _showPrice ? '1' : '0',
        _kTarget: '$_target',
      });
      if (_target == 0) {
        final bytes = await LabelPdf.build(
          widget.data,
          count: n,
          size: _size,
          kind: _kind,
          showName: _showName,
          showPrice: _showPrice,
        );
        final ok = await Printing.layoutPdf(
          name: 'Yorliq ${widget.data.code}',
          format: _size.pageFormat,
          onLayout: (_) async => bytes,
        );
        if (!ok) return;
      } else {
        await ref
            .read(printerServiceProvider)
            .printLabels(
              _target,
              widget.data,
              count: n,
              size: _size,
              kind: _kind,
              showName: _showName,
              showPrice: _showPrice,
            );
      }
      if (mounted) {
        showMessage(context, '$n ta yorliq chop etishga yuborildi');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showMessage(context, 'Chop etib bo\'lmadi: $e', error: true);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid = LabelPdf.canEncode(widget.data.code, _kind);
    return AlertDialog(
      title: const Text('Yorliq chop etish'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.data.name.isNotEmpty) Text(widget.data.name, style: Theme.of(context).textTheme.titleSmall),
              Text('Kod: ${widget.data.code}', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Printer', prefixIcon: Icon(Icons.print_outlined)),
                items: [
                  for (final slot in [2, 1]) DropdownMenuItem(value: slot, child: Text(_printerTitle(slot))),
                  const DropdownMenuItem(value: 0, child: Text('Boshqa printer (Windows oynasida tanlash)')),
                ],
                onChanged: (v) => setState(() => _target = v ?? _target),
              ),
              if (_target != 0 && !(_configs[_target]?.enabled ?? false))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    "$_target-printer sozlanmagan: Sozlamalar → Printerlar bo'limida ulang",
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              SegmentedButton<LabelCodeKind>(
                segments: [
                  for (final k in LabelCodeKind.values)
                    ButtonSegment(
                      value: k,
                      label: Text(k.label),
                      icon: Icon(k == LabelCodeKind.qr ? Icons.qr_code_2 : Icons.view_week_outlined),
                    ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_usesPdf)
                    Expanded(
                      child: DropdownButtonFormField<LabelSize>(
                        initialValue: _size,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: "Yorliq o'lchami"),
                        items: [for (final s in LabelSize.values) DropdownMenuItem(value: s, child: Text(s.label))],
                        onChanged: (v) => setState(() => _size = v ?? _size),
                      ),
                    ),
                  if (_usesPdf) const SizedBox(width: 12) else const Spacer(),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _count,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: 'Soni',
                        prefixIcon: IconButton(
                          icon: const Icon(Icons.remove),
                          onPressed: _n > 1 ? () => setState(() => _count.text = '${_n - 1}') : null,
                        ),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => setState(() => _count.text = '${_n + 1}'),
                        ),
                      ),
                      textAlign: TextAlign.center,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => valid && _ready ? _print() : null,
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _showName,
                title: const Text('Tovar nomi'),
                onChanged: (v) => setState(() => _showName = v ?? true),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _showPrice,
                title: const Text('Narxi'),
                onChanged: (v) => setState(() => _showPrice = v ?? true),
              ),
              if (!valid)
                Text(
                  "Bu kodni ${_kind.label.toLowerCase()} sifatida chop etib bo'lmaydi",
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: PdfPreview(
                    key: ValueKey('${_size.code}${_kind.code}$_showName$_showPrice'),
                    build: (_) => LabelPdf.build(
                      widget.data,
                      count: 1,
                      size: _size,
                      kind: _kind,
                      showName: _showName,
                      showPrice: _showPrice,
                    ),
                    useActions: false,
                    canChangePageFormat: false,
                    canChangeOrientation: false,
                    canDebug: false,
                    maxPageWidth: 400,
                    pdfPreviewPageDecoration: const BoxDecoration(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Bekor qilish')),
        FilledButton.icon(
          onPressed: valid && _ready && !_printing && _n >= 1 ? _print : null,
          icon: _printing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.print),
          label: Text('Chop etish ($_n ta)'),
        ),
      ],
    );
  }
}
