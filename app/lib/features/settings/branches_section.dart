import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/database.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';

/// Filiallar ro'yxati (faqat bosh admin). Tovarlar umumiy, savdo, ombor
/// qoldig'i, firmalar bilan hisob-kitob va jurnal — har bir filialda alohida.
class BranchesSection extends ConsumerWidget {
  const BranchesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchesProvider).value ?? const <Branch>[];
    final current = ref.watch(currentBranchProvider);
    return SectionCard(
      title: 'Filiallar',
      trailing: TextButton.icon(
        icon: const Icon(Icons.add),
        label: const Text("Filial qo'shish"),
        onPressed: () => showBranchDialog(context, ref),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          "Tovarlar va shtrix-kodlar hamma filialda bir xil. Savdo tarixi, ombordagi qoldiq, kirimlar va "
          "qarzlar har bir filialda alohida. Yuqori paneldan filialni tanlang. Bu qurilma hozir: "
          "${branches.where((b) => b.id == current).firstOrNull?.name ?? ''}.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final b in branches)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.store, color: b.isActive ? Theme.of(context).colorScheme.primary : Colors.grey),
            title: Text('${b.name}${b.isActive ? '' : ' (yopilgan)'}'),
            subtitle: Text([b.address, b.phone].where((x) => x.isNotEmpty).join(' · ')),
            onTap: () => showBranchDialog(context, ref, branch: b),
            trailing: b.id == current
                ? const Chip(label: Text('Shu qurilma'), visualDensity: VisualDensity.compact)
                : TextButton(
                    onPressed: b.isActive ? () => ref.read(currentBranchProvider.notifier).select(b.id) : null,
                    child: const Text("O'tish"),
                  ),
          ),
      ]),
    );
  }
}

Future<void> showBranchDialog(BuildContext context, WidgetRef ref, {Branch? branch}) async {
  final name = TextEditingController(text: branch?.name ?? '');
  final address = TextEditingController(text: branch?.address ?? '');
  final phone = TextEditingController(text: branch?.phone ?? '');
  var active = branch?.isActive ?? true;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(branch == null ? 'Yangi filial' : 'Filial'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nomi *')),
              const SizedBox(height: 10),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Manzil')),
              const SizedBox(height: 10),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Telefon')),
              if (branch != null && branch.id != kDefaultBranchId)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  onChanged: (v) => setState(() => active = v),
                  title: const Text('Ishlayapti'),
                ),
              if (error != null) Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
            ]),
          ),
        ),
        actions: [
          if (branch != null && branch.id != kDefaultBranchId)
            TextButton(
              onPressed: () async {
                if (branch.id == ref.read(currentBranchProvider)) {
                  setState(() => error = "Avval boshqa filialga o'ting");
                  return;
                }
                final ok = await confirmDialog(c, "Filialni o'chirish",
                    "${branch.name} ro'yxatdan o'chirilsinmi? Uning savdo tarixi saqlanib qoladi.",
                    danger: true, ok: "O'chirish");
                if (!ok) return;
                await ref.read(branchRepoProvider).delete(branch.id);
                await ref.read(activityRepoProvider).log('branch_deleted', details: branch.name, refId: branch.id, global: true);
                ref.read(syncServiceProvider).requestSync();
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text("O'chirish"),
            ),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Bekor qilish')),
          FilledButton(
            onPressed: () async {
              try {
                final id = await ref.read(branchRepoProvider).save(
                      id: branch?.id,
                      name: name.text,
                      address: address.text,
                      phone: phone.text,
                      isActive: active,
                    );
                await ref.read(activityRepoProvider).log('branch_saved', details: name.text.trim(), refId: id, global: true);
                ref.read(syncServiceProvider).requestSync();
                if (c.mounted) Navigator.pop(c);
              } catch (e) {
                setState(() => error = e.toString().replaceFirst('Exception: ', ''));
              }
            },
            child: const Text('Saqlash'),
          ),
        ],
      ),
    ),
  );
  for (final x in [name, address, phone]) {
    x.dispose();
  }
}
