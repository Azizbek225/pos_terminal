import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../state/providers.dart';
import '../dashboard/dashboard_page.dart';
import '../shell/common_widgets.dart';

final _alertsProvider = StreamProvider.family<List<Alert>, bool>(
    (ref, unreadOnly) => ref.watch(alertRepoProvider).watchAll(unreadOnly: unreadOnly));

class AlertsPage extends ConsumerStatefulWidget {
  const AlertsPage({super.key});

  @override
  ConsumerState<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends ConsumerState<AlertsPage> {
  bool _unreadOnly = true;
  AlertType? _type;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(_alertsProvider(_unreadOnly)).value ?? const <Alert>[];
    final list = _type == null ? all : all.where((a) => a.type == _type!.code).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterChip(
            label: const Text("Faqat o'qilmaganlar"),
            selected: _unreadOnly,
            onSelected: (v) => setState(() => _unreadOnly = v),
          ),
          DropdownButton<AlertType?>(
            value: _type,
            hint: const Text('Barcha turlar'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Barcha turlar')),
              for (final t in AlertType.values) DropdownMenuItem(value: t, child: Text(t.label)),
            ],
            onChanged: (v) => setState(() => _type = v),
          ),
          FilledButton.tonalIcon(
            onPressed: () => ref.read(alertRepoProvider).markAllRead(),
            icon: const Icon(Icons.done_all),
            label: const Text("Hammasini o'qilgan qilish"),
          ),
          OutlinedButton.icon(
            onPressed: list.isEmpty
                ? null
                : () async {
                    final what = _type == null ? 'barcha alertlar' : '"${_type!.label}" alertlari';
                    if (await confirmDialog(context, "Alertlarni o'chirish", "Ro'yxatdagi $what o'chirilsinmi?")) {
                      final repo = ref.read(alertRepoProvider);
                      for (final a in list) {
                        await repo.delete(a.id);
                      }
                    }
                  },
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text("O'chirish"),
          ),
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? const EmptyState(icon: Icons.notifications_off_outlined, text: "Alertlar yo'q")
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final a = list[i];
                  // Chapga/o'ngga surib bitta alertni o'chirish.
                  return Dismissible(
                    key: ValueKey(a.id),
                    onDismissed: (_) => ref.read(alertRepoProvider).delete(a.id),
                    child: Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: alertColor(context, a.severity).withValues(alpha: 0.15),
                        child: Icon(alertIcon(a.type), color: alertColor(context, a.severity)),
                      ),
                      title: Text(a.title,
                          style: TextStyle(fontWeight: a.isRead ? FontWeight.normal : FontWeight.bold)),
                      subtitle: Text(
                          '${a.message}\n${AlertType.fromCode(a.type).label} · ${Fmt.dateTimeMs(a.createdAt)}'),
                      isThreeLine: true,
                      trailing: a.isRead
                          ? const Icon(Icons.check, color: Colors.grey)
                          : IconButton(
                              tooltip: "O'qilgan deb belgilash",
                              icon: const Icon(Icons.mark_email_read_outlined),
                              onPressed: () => ref.read(alertRepoProvider).markRead(a.id),
                            ),
                    ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
