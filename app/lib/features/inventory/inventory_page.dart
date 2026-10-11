import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/database.dart';
import '../../data/repositories/product_repository.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'categories_tab.dart';
import 'movements_tab.dart';
import 'product_form_page.dart';
import 'receive_tab.dart';
import 'stock_movement_dialog.dart';

/// Ombor moduli: tovarlar va real-time qoldiq, kirim (skaner), harakatlar, kategoriyalar.
class InventoryPage extends StatelessWidget {
  const InventoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 4,
      child: Column(children: [
        TabBar(
          isScrollable: true,
          tabs: [
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Tovarlar va qoldiq'),
            Tab(icon: Icon(Icons.move_to_inbox_outlined), text: 'Kirim (skaner)'),
            Tab(icon: Icon(Icons.swap_vert), text: 'Harakatlar'),
            Tab(icon: Icon(Icons.category_outlined), text: 'Kategoriyalar'),
          ],
        ),
        Expanded(
          child: TabBarView(children: [
            _ProductsTab(),
            ReceiveTab(),
            MovementsTab(),
            CategoriesTab(),
          ]),
        ),
      ]),
    );
  }
}

final _productListProvider =
    StreamProvider.family<List<Product>, ProductFilter>((ref, f) => ref.watch(productRepoProvider).watch(f));

class _ProductsTab extends ConsumerStatefulWidget {
  const _ProductsTab();

  @override
  ConsumerState<_ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends ConsumerState<_ProductsTab> {
  String _query = '';
  String? _categoryId;
  bool _lowOnly = false;
  bool _inactive = false;

  @override
  Widget build(BuildContext context) {
    final filter = ProductFilter(
      query: _query,
      categoryId: _categoryId,
      lowStockOnly: _lowOnly,
      includeInactive: _inactive,
      limit: 1000,
    );
    final products = ref.watch(_productListProvider(filter));
    final categories = ref.watch(categoriesProvider).value ?? const [];
    final catNames = {for (final c in categories) c.id: c.name};

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openProductForm(context),
        icon: const Icon(Icons.add),
        label: const Text('Yangi tovar'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 340,
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Nom, shtrix-kod, artikul, brend...',
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            DropdownButton<String?>(
              value: _categoryId,
              hint: const Text('Barcha kategoriyalar'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Barcha kategoriyalar')),
                for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _categoryId = v),
            ),
            FilterChip(
              avatar: const Icon(Icons.warning_amber, size: 18),
              label: const Text('Kam qolganlar'),
              selected: _lowOnly,
              onSelected: (v) => setState(() => _lowOnly = v),
            ),
            FilterChip(
              label: const Text('Nofaollar ham'),
              selected: _inactive,
              onSelected: (v) => setState(() => _inactive = v),
            ),
          ]),
        ),
        Expanded(
          child: products.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Xato: $e')),
            data: (list) => list.isEmpty
                ? const EmptyState(icon: Icons.inventory_2_outlined, text: 'Tovar topilmadi')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _ProductRow(product: list[i], categoryName: catNames[list[i].categoryId]),
                  ),
          ),
        ),
      ]),
    );
  }
}

class _ProductRow extends ConsumerWidget {
  const _ProductRow({required this.product, this.categoryName});
  final Product product;
  final String? categoryName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = product;
    final theme = Theme.of(context);
    final low = p.minStock > 0 && p.stockQty <= p.minStock;
    final out = p.stockQty <= 0;
    final stockColor = out ? theme.colorScheme.error : (low ? AppTheme.warning(context) : AppTheme.success(context));
    final role = ref.watch(currentRoleProvider);

    return ListTile(
      onTap: () => openProductForm(context, product: p),
      leading: ProductThumb(
        imagePath: p.imagePath,
        size: 44,
        fallback: CircleAvatar(
          backgroundColor: stockColor.withValues(alpha: 0.15),
          child: Icon(out ? Icons.error_outline : (low ? Icons.warning_amber : Icons.check), color: stockColor),
        ),
      ),
      title: Text(p.name + (p.isActive ? '' : '  (nofaol)'), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (p.barcode.isNotEmpty) p.barcode,
          if (p.sku.isNotEmpty) 'Art: ${p.sku}',
          ?categoryName,
          if (p.location.isNotEmpty) 'Joy: ${p.location}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${Fmt.qty(p.stockQty)} ${p.unit}', style: TextStyle(fontWeight: FontWeight.bold, color: stockColor)),
          Text(Fmt.money(p.salePrice), style: theme.textTheme.bodySmall),
        ]),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'edit':
                await openProductForm(context, product: p);
              case 'move':
                await showStockMovementDialog(context, ref, p);
              case 'delete':
                if (await confirmDialog(context, "Tovarni o'chirish", '${p.name} o\'chirilsinmi?', danger: true, ok: "O'chirish")) {
                  await ref.read(productRepoProvider).softDelete(p.id);
                }
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Tahrirlash')),
            const PopupMenuItem(value: 'move', child: Text('Chiqim / qaytarish / inventarizatsiya')),
            if (role == UserRole.admin) const PopupMenuItem(value: 'delete', child: Text("O'chirish")),
          ],
        ),
      ]),
    );
  }
}
