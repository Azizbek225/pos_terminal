import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/common_widgets.dart';
import '../../../core/formatters.dart';
import '../../../data/database.dart';
import '../../../services/scanner/camera_scanner.dart';
import '../../../state/providers.dart';

/// Tezkor qidiruv maydoni: nom, shtrix-kod, artikul, brend yoki kategoriya.
///
/// * Skaner kodni shu maydonga yozib Enter bossa — aniq shtrix-kod bo'yicha
///   topilgan tovar darhol savatga qo'shiladi.
/// * Qo'lda yozilganda — natijalar ro'yxati chiqadi (strelkalar + Enter bilan tanlanadi).
class ProductSearchField extends ConsumerStatefulWidget {
  const ProductSearchField({super.key, required this.onPicked, this.focusNode, this.hint, this.onNotFound});

  final void Function(Product p) onPicked;

  /// Kod topilmaganda (masalan, kirimda yangi tovar yaratish uchun).
  final void Function(String code)? onNotFound;
  final FocusNode? focusNode;
  final String? hint;

  @override
  ConsumerState<ProductSearchField> createState() => ProductSearchFieldState();
}

class ProductSearchFieldState extends ConsumerState<ProductSearchField> {
  final _controller = TextEditingController();
  late final FocusNode _focus = widget.focusNode ?? FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void focus() => _focus.requestFocus();

  /// Shtrix-kod yoki artikulga o'xshash matn: bo'shliqsiz va kamida bitta raqamli.
  static bool _looksLikeCode(String s) => RegExp(r'^[0-9A-Za-z\-_./]+$').hasMatch(s) && RegExp(r'[0-9]').hasMatch(s);

  void _clear() {
    // RawAutocomplete matnni tanlangan qiymat bilan to'ldiradi — keyingi kadrda tozalaymiz.
    scheduleMicrotask(() {
      _controller.clear();
      _focus.requestFocus();
    });
  }

  /// Kod bo'yicha qidirish (skaner yoki kamera). Topilmasa — xabar.
  Future<bool> handleCode(String code) async {
    final p = await ref.read(productRepoProvider).findByBarcode(code);
    if (!mounted) return false;
    if (p == null) {
      if (widget.onNotFound != null) {
        widget.onNotFound!(code);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tovar topilmadi: $code'), margin: snackMargin(context)));
      }
      return false;
    }
    widget.onPicked(p);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Product>(
      textEditingController: _controller,
      focusNode: _focus,
      displayStringForOption: (p) => p.name,
      optionsBuilder: (value) async {
        final q = value.text.trim();
        if (q.length < 2) return const [];
        return ref.read(productRepoProvider).search(q, limit: 20);
      },
      onSelected: (p) {
        widget.onPicked(p);
        _clear();
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: widget.hint ?? "Qidiruv: nom, shtrix-kod, artikul, kategoriya  (F2)",
            prefixIcon: const Icon(Icons.search),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller.text.isNotEmpty)
                  IconButton(icon: const Icon(Icons.clear), onPressed: () => controller.clear()),
                if (cameraScanSupported)
                  IconButton(
                    tooltip: 'Kamera bilan skanerlash',
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: () async {
                      final code = await scanWithCamera(context);
                      if (code != null) await handleCode(code);
                    },
                  ),
              ],
            ),
          ),
          onChanged: (_) => setState(() {}),
          // Enter bosilganda maydon fokusni yo'qotmasin (skaner ketma-ket ishlashi uchun).
          onEditingComplete: () {},
          onSubmitted: (v) async {
            final text = v.trim();
            if (text.isEmpty) return;
            // Oddiy matn (nom) — ro'yxatdagi belgilangan variant darhol tanlanadi.
            if (!_looksLikeCode(text)) {
              onFieldSubmitted();
              return;
            }
            // Kodga o'xshash (shtrix-kod / artikul) — avval aniq moslik.
            final p = await ref.read(productRepoProvider).findByBarcode(text);
            if (p != null) {
              widget.onPicked(p);
              _clear();
              return;
            }
            final results = await ref.read(productRepoProvider).search(text, limit: 2);
            if (results.isNotEmpty) {
              onFieldSubmitted();
            } else if (widget.onNotFound != null) {
              controller.clear();
              widget.onNotFound!(text);
            } else if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tovar topilmadi: $text'), margin: snackMargin(context)));
              focusNode.requestFocus();
            }
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final theme = Theme.of(context);
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420, maxWidth: 640),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final p = options.elementAt(i);
                  final highlighted = AutocompleteHighlightedOption.of(context) == i;
                  final low = p.minStock > 0 && p.stockQty <= p.minStock;
                  return ListTile(
                    dense: true,
                    tileColor: highlighted ? theme.colorScheme.primary.withValues(alpha: 0.1) : null,
                    leading: ProductThumb(imagePath: p.imagePath, size: 48),
                    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (p.barcode.isNotEmpty) p.barcode,
                        if (p.sku.isNotEmpty) 'Art: ${p.sku}',
                        if (p.brand.isNotEmpty) p.brand,
                      ].join(' · '),
                      maxLines: 1,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(Fmt.money(p.salePrice), style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          'Qoldiq: ${Fmt.qty(p.stockQty)} ${p.unit}',
                          style: TextStyle(fontSize: 12, color: low ? theme.colorScheme.error : null),
                        ),
                      ],
                    ),
                    onTap: () => onSelected(p),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
