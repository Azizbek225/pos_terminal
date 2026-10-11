import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

const _palette = [
  0xFFEF6C00, 0xFF0288D1, 0xFF7CB342, 0xFFFBC02D, 0xFF26A69A,
  0xFF388E3C, 0xFFD32F2F, 0xFF5D4037, 0xFF8E24AA, 0xFF607D8B,
];

class CategoriesTab extends ConsumerWidget {
  const CategoriesTab({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [ProductCategory? cat]) async {
    final ctrl = TextEditingController(text: cat?.name ?? '');
    var color = cat?.color ?? _palette.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(cat == null ? 'Yangi kategoriya' : 'Kategoriyani tahrirlash'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Nomi')),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _palette)
                GestureDetector(
                  onTap: () => setState(() => color = p),
                  child: CircleAvatar(
                    backgroundColor: Color(p),
                    radius: 16,
                    child: color == p ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Bekor qilish')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Saqlash')),
          ],
        ),
      ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      await ref.read(productRepoProvider).saveCategory(id: cat?.id, name: ctrl.text.trim(), color: color);
    }
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(categoriesProvider).value ?? const [];
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Kategoriya'),
      ),
      body: list.isEmpty
          ? const EmptyState(icon: Icons.category_outlined, text: "Kategoriyalar yo'q")
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final cat = list[i];
                return ListTile(
                  leading: CircleAvatar(backgroundColor: Color(cat.color), radius: 12),
                  title: Text(cat.name),
                  onTap: () => _edit(context, ref, cat),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirmDialog(context, "Kategoriyani o'chirish",
                          '"${cat.name}" o\'chirilsinmi? Tovarlar o\'chirilmaydi.', danger: true, ok: "O'chirish")) {
                        await ref.read(productRepoProvider).deleteCategory(cat.id);
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}
