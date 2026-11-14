import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/currency.dart';
import '../../core/formatters.dart';
import '../../data/database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../state/providers.dart';
import 'common_widgets.dart';

String _source(String s) => switch (s) {
      'cbu' => 'Markaziy bank',
      'manual' => "qo'lda",
      'server' => 'server',
      _ => 'internet',
    };

/// Asosiy ekrandagi dollar kursi: bosilsa — kursni yangilash / qo'lda kiritish.
class UsdRateChip extends ConsumerWidget {
  const UsdRateChip({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(usdRateRecordProvider).value;
    final theme = Theme.of(context);
    final color = Colors.green.shade700;
    return Tooltip(
      message: r == null
          ? 'Dollar kursi hali yo\'q — bosib kiriting'
          : 'Kurs: ${_source(r.source)}, ${Fmt.dateTimeMs(r.createdAt)}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showCurrencyDialog(context, ref),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: compact ? 4 : 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.attach_money, color: color, size: 22),
            const SizedBox(width: 4),
            Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Dollar kursi', style: theme.textTheme.labelSmall),
              Text(
                r == null ? '— kiriting' : Fmt.money(r.rate.round()),
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: color),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Kurs oynasi: joriy kurs, internetdan yangilash, qo'lda kiritish va tarix.
Future<void> showCurrencyDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(context: context, builder: (_) => const _CurrencyDialog());

class _CurrencyDialog extends ConsumerStatefulWidget {
  const _CurrencyDialog();

  @override
  ConsumerState<_CurrencyDialog> createState() => _CurrencyDialogState();
}

class _CurrencyDialogState extends ConsumerState<_CurrencyDialog> {
  final _rate = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final service = ref.read(currencyServiceProvider);
    final ok = await service.refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    ref.read(syncServiceProvider).requestSync();
    showMessage(context, ok ? 'Kurs yangilandi' : (service.lastError.value ?? 'Kurs olinmadi'), error: !ok);
  }

  Future<void> _saveManual() async {
    final v = Fmt.parseNum(_rate.text) ?? 0;
    if (v < 1000 || v > 100000) {
      showMessage(context, "Kursni to'g'ri kiriting (masalan 12 050)", error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(currencyRepoProvider).saveRate(
            rate: v,
            source: 'manual',
            userName: ref.read(authProvider)?.fullName ?? '',
          );
      ref.read(syncServiceProvider).requestSync();
      if (mounted) {
        _rate.clear();
        showMessage(context, "Kurs saqlandi: ${Fmt.money(v)}");
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = ref.watch(usdRateRecordProvider).value;
    final isAdmin = ref.watch(authProvider.notifier).isAdmin;
    return AlertDialog(
      title: const Text('Dollar kursi'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            current == null ? "Kurs hali yo'q" : "1\$ = ${Money.rate(current.rate)} so'm",
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (current != null)
            Text('${_source(current.source)} · ${Fmt.dateTimeMs(current.createdAt)}'
                '${current.userName.isEmpty ? '' : ' · ${current.userName}'}'),
          const SizedBox(height: 8),
          Text(
            "Kurs internetdan kuniga 2 marta (ertalab va tushdan keyin) o'zi yangilanadi. "
            "Dollar narxli tovarlar: kurs oshsa so'm narx ham oshadi, tushsa — o'zgarmaydi.",
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Internetdan hozir olish'),
          ),
          if (isAdmin) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9., ]'))],
              decoration: InputDecoration(
                labelText: "Qo'lda kiritish (1\$ necha so'm)",
                suffixText: "so'm",
                suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: _busy ? null : _saveManual),
              ),
              onSubmitted: (_) => _saveManual(),
            ),
          ],
          const SizedBox(height: 12),
          Text('Oxirgi kurslar', style: theme.textTheme.titleSmall),
          SizedBox(height: 160, child: _History()),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Yopish'))],
    );
  }
}

final _historyProvider =
    StreamProvider<List<CurrencyRate>>((ref) => ref.watch(currencyRepoProvider).watchHistory(limit: 20));

class _History extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_historyProvider).value ?? const <CurrencyRate>[];
    if (list.isEmpty) return const Center(child: Text("Hali yo'q"));
    return ListView(children: [
      for (final r in list)
        ListTile(
          dense: true,
          title: Text("${Money.rate(r.rate)} so'm"),
          subtitle: Text('${_source(r.source)}${r.userName.isEmpty ? '' : ' · ${r.userName}'}'),
          trailing: Text(Fmt.dateTimeMs(r.createdAt)),
        ),
    ]);
  }
}

/// Sozlamalar: avtomatik kurs, yaxlitlash va chekda dollar.
class CurrencySettingsSection extends ConsumerWidget {
  const CurrencySettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider).value ?? const <String, String>{};
    final repo = ref.read(settingsRepoProvider);
    final step = ref.watch(usdRoundStepProvider);
    final rate = ref.watch(usdRateProvider);
    return SectionCard(
      title: 'Dollar (valyuta)',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.attach_money),
          title: Text(rate > 0 ? "Joriy kurs: 1\$ = ${Fmt.money(rate)}" : 'Kurs hali kiritilmagan'),
          trailing: OutlinedButton(onPressed: () => showCurrencyDialog(context, ref), child: const Text("O'zgartirish")),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: (s[SettingKeys.currencyAuto] ?? '1') == '1',
          onChanged: (v) => repo.set(SettingKeys.currencyAuto, v ? '1' : '0'),
          title: const Text('Kursni internetdan avtomatik olish'),
          subtitle: const Text("Ertalab va tushdan keyin (Markaziy bank kursi)"),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: s[SettingKeys.receiptUsd] == '1',
          onChanged: (v) => repo.set(SettingKeys.receiptUsd, v == true ? '1' : '0'),
          title: const Text('Chekda dollar narxlar ham chiqsin'),
          subtitle: const Text("O'chiq bo'lsa chek faqat so'mda"),
        ),
        Row(children: [
          const Expanded(child: Text("Dollar narx so'mga yaxlitlanadi (yuqoriga):")),
          DropdownButton<int>(
            value: const [1, 100, 500, 1000].contains(step) ? step : 100,
            items: [
              for (final v in const [1, 100, 500, 1000])
                DropdownMenuItem(value: v, child: Text(v == 1 ? 'yaxlitlamaslik' : "$v so'm")),
            ],
            onChanged: (v) => repo.set(SettingKeys.currencyRoundStep, '${v ?? 100}'),
          ),
        ]),
      ]),
    );
  }
}
