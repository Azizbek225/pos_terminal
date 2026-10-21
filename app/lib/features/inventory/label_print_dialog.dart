import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../services/printing/label.dart';
import '../../services/printing/printer_config.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

/// Yorliq chop etish faqat kompyuterda.
bool get labelPrintSupported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

const _kKind = 'label.kind';
const _kName = 'label.showName';
const _kPrice = 'label.showPrice';
const _kTarget = 'label.printer'; // 1 | 2

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
  LabelCodeKind _kind = LabelCodeKind.barcode;
  bool _showName = true;
  bool _showPrice = true;
  bool _printing = false;

  /// Sozlamalardagi 1- yoki 2-printer.
  int _target = 2;
  final _configs = <int, PrinterConfig>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = ref.read(settingsRepoProvider);
    final kind = await s.get(_kKind);
    final name = await s.get(_kName), price = await s.get(_kPrice);
    final target = int.tryParse(await s.get(_kTarget) ?? '');
    final printers = ref.read(printerServiceProvider);
    final c1 = await printers.config(1), c2 = await printers.config(2);
    if (!mounted) return;
    setState(() {
      _configs
        ..[1] = c1
        ..[2] = c2;
      _target = target == 1 ? 1 : 2;
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

  String _printerTitle(int slot) {
    final c = _configs[slot];
    if (c == null || !c.enabled) return '$slot-printer (sozlanmagan)';
    return '$slot-printer: ${c.name.isEmpty ? c.address : c.name}';
  }

  bool get _ready => _configs[_target]?.enabled ?? false;

  Future<void> _print() async {
    final n = _n;
    if (n < 1 || n > 1000) {
      showMessage(context, 'Soni 1 dan 1000 gacha bo\'lishi kerak', error: true);
      return;
    }
    setState(() => _printing = true);
    try {
      await ref.read(settingsRepoProvider).setAll({
        _kKind: _kind.code,
        _kName: _showName ? '1' : '0',
        _kPrice: _showPrice ? '1' : '0',
        _kTarget: '$_target',
      });
      await ref
          .read(printerServiceProvider)
          .printLabels(_target, widget.data, count: n, kind: _kind, showName: _showName, showPrice: _showPrice);
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
    final valid = LabelData.canEncode(widget.data.code, _kind);
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
                ],
                onChanged: (v) => setState(() => _target = v ?? _target),
              ),
              if (_configs.isNotEmpty && !_ready)
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
                  const Spacer(),
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
                _Preview(data: widget.data, kind: _kind, showName: _showName, showPrice: _showPrice),
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

/// Yorliqning taxminiy ko'rinishi (printer chiqaradigan tartibda).
class _Preview extends StatelessWidget {
  const _Preview({required this.data, required this.kind, required this.showName, required this.showPrice});
  final LabelData data;
  final LabelCodeKind kind;
  final bool showName;
  final bool showPrice;

  @override
  Widget build(BuildContext context) {
    const ink = TextStyle(color: Colors.black);
    return Center(
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black26),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showName && data.name.isNotEmpty)
              Text(
                data.name,
                textAlign: TextAlign.center,
                style: ink.copyWith(fontWeight: FontWeight.bold),
              ),
            if (showPrice && data.price > 0)
              Text(Fmt.money(data.price), style: ink.copyWith(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Icon(kind == LabelCodeKind.qr ? Icons.qr_code_2 : Icons.view_week, size: 64, color: Colors.black),
            Text(data.code, style: ink.copyWith(fontSize: 12, letterSpacing: 1)),
          ],
        ),
      ),
    );
  }
}
