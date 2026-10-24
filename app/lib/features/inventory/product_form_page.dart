import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/season.dart';
import '../../data/database.dart';
import '../../data/repositories/stock_repository.dart';
import '../../services/printing/label.dart';
import '../../services/product_images.dart';
import '../../services/scanner/camera_scanner.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'label_print_dialog.dart';

/// Tovar kartasini ochish (yangi yoki tahrirlash). Qaytaradi: saqlangan tovar ID si.
Future<String?> openProductForm(BuildContext context, {Product? product, String? barcode}) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) => ProductFormPage(product: product, initialBarcode: barcode),
  ));
}

/// Tovar kartasi — standart atributlar to'liq to'plami.
class ProductFormPage extends ConsumerStatefulWidget {
  const ProductFormPage({super.key, this.product, this.initialBarcode});
  final Product? product;
  final String? initialBarcode;

  @override
  ConsumerState<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends ConsumerState<ProductFormPage> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};
  String? _categoryId;
  String _unit = 'dona';
  bool _isWeighted = false;
  bool _isActive = true;
  Set<Season> _seasons = {};
  bool _saving = false;
  String _imagePath = '';

  /// Shu formada tanlangan, lekin hali saqlanmagan rasmlar (bekor qilinsa o'chiriladi).
  final _pickedImages = <String>{};
  bool _saved = false;

  bool get _isNew => widget.product == null;

  TextEditingController c(String key) => _c.putIfAbsent(key, TextEditingController.new);

  /// Yorliq chop etish: kod bo'lmasa — ichki shtrix-kod yaratiladi.
  Future<void> _printLabel() async {
    var code = _t('barcode');
    if (code.isEmpty) {
      code = await ref.read(productRepoProvider).generateInternalBarcode();
      setState(() => c('barcode').text = code);
    }
    if (!mounted) return;
    if (code != (widget.product?.barcode ?? '')) {
      showMessage(context, "Yangi shtrix-kod tovar saqlangandan keyin ishlaydi — 'Saqlash' ni unutmang");
    }
    await showLabelPrintDialog(
      context,
      LabelData(code: code, name: _t('shortName').isEmpty ? _t('name') : _t('shortName'), price: _i('sale')),
    );
  }

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    String n(num v) => v == 0 ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
    c('name').text = p?.name ?? '';
    c('shortName').text = p?.shortName ?? '';
    c('sku').text = p?.sku ?? '';
    c('barcode').text = p?.barcode ?? widget.initialBarcode ?? '';
    c('barcode2').text = p?.barcode2 ?? '';
    c('description').text = p?.description ?? '';
    c('brand').text = p?.brand ?? '';
    c('manufacturer').text = p?.manufacturer ?? '';
    c('country').text = p?.country ?? '';
    c('supplier').text = p?.supplier ?? '';
    c('mxik').text = p?.mxikCode ?? '';
    c('packageCode').text = p?.packageCode ?? '';
    c('vat').text = p == null ? '12' : n(p.vatPercent);
    c('packQty').text = p == null ? '1' : n(p.packQty);
    c('purchase').text = n(p?.purchasePrice ?? 0);
    c('sale').text = n(p?.salePrice ?? 0);
    c('wholesale').text = n(p?.wholesalePrice ?? 0);
    c('minStock').text = n(p?.minStock ?? 0);
    c('maxStock').text = n(p?.maxStock ?? 0);
    c('location').text = p?.location ?? '';
    c('color').text = p?.color ?? '';
    c('size').text = p?.size ?? '';
    c('material').text = p?.material ?? '';
    c('weight').text = n(p?.weightKg ?? 0);
    c('volume').text = n(p?.volumeL ?? 0);
    c('warranty').text = n(p?.warrantyMonths ?? 0);
    c('notes').text = p?.notes ?? '';
    c('initialStock').text = '';
    _categoryId = p?.categoryId;
    _unit = p?.unit ?? 'dona';
    _isWeighted = p?.isWeighted ?? false;
    _isActive = p?.isActive ?? true;
    _seasons = parseSeasonTags(p?.seasonTags);
    _imagePath = p?.imagePath ?? '';
  }

  @override
  void dispose() {
    for (final x in _c.values) {
      x.dispose();
    }
    // Saqlanmagan yoki almashtirilgan rasmlar diskda qolib ketmasin.
    for (final name in _pickedImages) {
      if (!_saved || name != _imagePath) ProductImages.delete(name);
    }
    super.dispose();
  }

  double _d(String k) => Fmt.parseNum(c(k).text) ?? 0;
  int _i(String k) => _d(k).round();
  String _t(String k) => c(k).text.trim();

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(productRepoProvider);
    try {
      for (final key in ['barcode', 'barcode2']) {
        if (await repo.isBarcodeTaken(_t(key), exceptId: widget.product?.id)) {
          throw Exception('Shtrix-kod ${_t(key)} boshqa tovarda ishlatilgan');
        }
      }
      final data = ProductsCompanion(
        id: widget.product == null ? const Value.absent() : Value(widget.product!.id),
        name: Value(_t('name')),
        shortName: Value(_t('shortName')),
        sku: Value(_t('sku')),
        barcode: Value(_t('barcode')),
        barcode2: Value(_t('barcode2')),
        description: Value(_t('description')),
        categoryId: Value(_categoryId),
        brand: Value(_t('brand')),
        manufacturer: Value(_t('manufacturer')),
        country: Value(_t('country')),
        supplier: Value(_t('supplier')),
        mxikCode: Value(_t('mxik')),
        packageCode: Value(_t('packageCode')),
        vatPercent: Value(_d('vat')),
        unit: Value(_unit),
        packQty: Value(_d('packQty') <= 0 ? 1 : _d('packQty')),
        isWeighted: Value(_isWeighted),
        purchasePrice: Value(_i('purchase')),
        salePrice: Value(_i('sale')),
        wholesalePrice: Value(_i('wholesale')),
        minStock: Value(_d('minStock')),
        maxStock: Value(_d('maxStock')),
        location: Value(_t('location')),
        color: Value(_t('color')),
        size: Value(_t('size')),
        material: Value(_t('material')),
        weightKg: Value(_d('weight')),
        volumeL: Value(_d('volume')),
        warrantyMonths: Value(_i('warranty')),
        seasonTags: Value(encodeSeasonTags(_seasons)),
        isActive: Value(_isActive),
        notes: Value(_t('notes')),
        imagePath: Value(_imagePath),
      );
      final id = await repo.save(data);
      _saved = true;
      final oldImage = widget.product?.imagePath ?? '';
      if (oldImage.isNotEmpty && oldImage != _imagePath) await ProductImages.delete(oldImage);

      // Yangi tovar uchun boshlang'ich qoldiq — kirim harakati sifatida.
      final initial = _d('initialStock');
      final user = ref.read(authProvider)!;
      if (_isNew && initial > 0) {
        await ref.read(stockRepoProvider).addMovements([
          MovementInput(
            productId: id,
            type: MovementType.receipt,
            qty: initial,
            unitCost: _i('purchase'),
            note: "Boshlang'ich qoldiq",
          ),
        ], userId: user.id, userName: user.fullName);
      }
      await ref.read(alertServiceProvider).checkStock([id]);
      ref.read(syncServiceProvider).requestSync();
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) showMessage(context, e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickImage(bool camera) async {
    try {
      final name = await ProductImages.pick(context, camera: camera);
      if (name == null || !mounted) return;
      setState(() {
        _pickedImages.add(name);
        _imagePath = name;
      });
    } catch (e) {
      if (mounted) showMessage(context, 'Rasm olinmadi: $e', error: true);
    }
  }

  Widget _imageSection() {
    final has = ProductImages.exists(_imagePath);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      ProductThumb(imagePath: _imagePath, size: 112, radius: 12),
      const SizedBox(width: 16),
      Expanded(
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (ProductImages.cameraSupported)
            FilledButton.icon(
              onPressed: () => _pickImage(true),
              icon: const Icon(Icons.photo_camera),
              label: const Text('Suratga olish'),
            ),
          OutlinedButton.icon(
            onPressed: () => _pickImage(false),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(ProductImages.cameraSupported && !Platform.isWindows ? 'Galereyadan' : 'Fayldan tanlash'),
          ),
          if (has || _imagePath.isNotEmpty)
            TextButton.icon(
              onPressed: () => setState(() => _imagePath = ''),
              icon: const Icon(Icons.delete_outline),
              label: const Text("Rasmni o'chirish"),
            ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final purchase = _d('purchase');
    final sale = _d('sale');
    final margin = purchase > 0 && sale > 0 ? (sale - purchase) * 100 / purchase : null;

    Widget row(List<Widget> children) => wide
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: children[i])],
          ])
        : Column(children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 12), children[i]],
          ]);

    Widget text(String key, String label,
            {bool required = false, bool number = false, String? suffix, String? helper, int maxLines = 1, Widget? suffixIcon}) =>
        TextFormField(
          controller: c(key),
          maxLines: maxLines,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : null,
          inputFormatters: number ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9., ]'))] : null,
          decoration: InputDecoration(labelText: label + (required ? ' *' : ''), suffixText: suffix, helperText: helper, suffixIcon: suffixIcon),
          validator: required ? (v) => (v == null || v.trim().isEmpty) ? 'Majburiy maydon' : null : null,
          onChanged: number ? (_) => setState(() {}) : null,
        );

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: SectionCard(
            title: title,
            child: Column(children: [
              for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 12), children[i]],
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Yangi tovar' : 'Tovarni tahrirlash'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: const Text('Saqlash'),
            ),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            section('Asosiy ma\'lumotlar', [
              _imageSection(),
              text('name', "To'liq nomi", required: true),
              row([
                text('shortName', 'Chek uchun qisqa nom', helper: "Bo'sh bo'lsa to'liq nom chiqadi"),
                text('sku', 'Artikul (SKU)'),
              ]),
              row([
                text('barcode', 'Shtrix-kod (EAN-13/EAN-8/UPC/Code128)',
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (cameraScanSupported)
                        IconButton(
                          tooltip: 'Kamera bilan skanerlash',
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: () async {
                            final code = await scanWithCamera(context);
                            if (code != null) setState(() => c('barcode').text = code);
                          },
                        ),
                      IconButton(
                        tooltip: 'Ichki shtrix-kod yaratish',
                        icon: const Icon(Icons.auto_fix_high),
                        onPressed: () async {
                          final code = await ref.read(productRepoProvider).generateInternalBarcode();
                          setState(() => c('barcode').text = code);
                        },
                      ),
                      IconButton(
                        tooltip: 'Shtrix/QR-kod yorlig\'ini chop etish',
                        icon: const Icon(Icons.print_outlined),
                        onPressed: _printLabel,
                      ),
                    ])),
                text('barcode2', "Qo'shimcha shtrix-kod (qadoq)"),
              ]),
              row([
                DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: categories.any((x) => x.id == _categoryId) ? _categoryId : null,
                  decoration: const InputDecoration(labelText: 'Kategoriya'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— tanlanmagan —')),
                    for (final cat in categories) DropdownMenuItem(value: cat.id, child: Text(cat.name)),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
                text('brand', 'Brend'),
              ]),
              text('description', 'Tavsif', maxLines: 2),
            ]),
            section("Narxlar (so'm)", [
              row([
                text('purchase', 'Kirim narxi', number: true, suffix: "so'm"),
                text('sale', 'Sotuv narxi', required: true, number: true, suffix: "so'm",
                    helper: margin == null ? null : 'Ustama: ${margin.toStringAsFixed(1)}%'),
                text('wholesale', 'Ulgurji narx', number: true, suffix: "so'm"),
              ]),
            ]),
            section("O'lchov va ombor", [
              row([
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: kUnits.contains(_unit) ? _unit : 'dona',
                  decoration: const InputDecoration(labelText: "O'lchov birligi"),
                  items: [for (final u in kUnits) DropdownMenuItem(value: u, child: Text(u))],
                  onChanged: (v) => setState(() => _unit = v ?? 'dona'),
                ),
                text('packQty', 'Qadoqdagi soni', number: true),
                text('location', 'Joylashuv (javon/qator)'),
              ]),
              row([
                text('minStock', 'Minimal qoldiq (alert chegarasi)', number: true, suffix: _unit),
                text('maxStock', 'Maksimal qoldiq', number: true, suffix: _unit),
                if (_isNew)
                  text('initialStock', "Boshlang'ich qoldiq", number: true, suffix: _unit)
                else
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Joriy qoldiq (shu filial)'),
                    child: Text('${Fmt.qty(widget.product!.stockQty)} $_unit'),
                  ),
              ]),
              if (!_isNew) _BranchStock(productId: widget.product!.id, unit: _unit),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isWeighted,
                onChanged: (v) => setState(() => _isWeighted = v),
                title: const Text('Vaznli / kasr miqdorli tovar (kg, metr)'),
              ),
            ]),
            section('Soliq (fiskal) ma\'lumotlari', [
              row([
                text('mxik', 'MXIK (IKPU) kodi', helper: 'tasnif.soliq.uz dan olinadi'),
                text('packageCode', "Qadoq / o'lchov birligi kodi"),
                text('vat', 'QQS stavkasi', number: true, suffix: '%'),
              ]),
            ]),
            section('Ishlab chiqaruvchi va xususiyatlar', [
              row([text('manufacturer', 'Ishlab chiqaruvchi'), text('country', 'Mamlakat'), text('supplier', 'Yetkazib beruvchi')]),
              row([text('material', 'Material'), text('color', 'Rang'), text('size', "O'lcham")]),
              row([
                text('weight', "Og'irligi", number: true, suffix: 'kg'),
                text('volume', 'Hajmi', number: true, suffix: 'L'),
                text('warranty', 'Kafolat', number: true, suffix: 'oy'),
              ]),
            ]),
            section('Mavsumiylik', [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text("Tovar qaysi mavsumda talab yuqori? (bo'sh — barcha mavsum)"),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 8, children: [
                  for (final s in Season.values)
                    FilterChip(
                      label: Text('${s.emoji} ${s.label}'),
                      selected: _seasons.contains(s),
                      onSelected: (v) => setState(() => v ? _seasons.add(s) : _seasons.remove(s)),
                    ),
                ]),
              ),
            ]),
            section('Boshqa', [
              text('notes', 'Izoh', maxLines: 2),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
                title: const Text('Faol (sotuvda)'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Tovarning boshqa filiallardagi qoldig'i (filial bittadan ko'p bo'lsa).
class _BranchStock extends ConsumerWidget {
  const _BranchStock({required this.productId, required this.unit});
  final String productId;
  final String unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = (ref.watch(branchesProvider).value ?? const <Branch>[]).where((b) => b.isActive).toList();
    if (branches.length < 2) return const SizedBox.shrink();
    return FutureBuilder<Map<String, double>>(
      future: ref.read(stockRepoProvider).stockByBranch(productId),
      builder: (context, snap) {
        final m = snap.data ?? const <String, double>{};
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final b in branches) Chip(label: Text('${b.name}: ${Fmt.qty(m[b.id] ?? 0)} $unit')),
          ]),
        );
      },
    );
  }
}
