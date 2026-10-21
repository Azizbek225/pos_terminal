import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../services/demo_data.dart';
import '../../services/printing/printer_config.dart';
import '../../services/sync/sync_service.dart';
import '../../services/sync/server_discovery.dart';
import '../../core/formatters.dart';
import '../../state/providers.dart';
import '../shell/common_widgets.dart';
import 'branches_section.dart';

/// Sozlamalar: do'kon, printerlar, alertlar, sinxronlash, ko'rinish, ma'lumotlar.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return settings.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Xato: $e')),
      data: (s) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StoreSection(values: s),
          const SizedBox(height: 16),
          if (ref.watch(isOwnerProvider)) ...[
            const BranchesSection(),
            const SizedBox(height: 16),
          ],
          const _PrintersSection(),
          const SizedBox(height: 16),
          _AlertsSection(values: s),
          const SizedBox(height: 16),
          _SyncSection(values: s),
          const SizedBox(height: 16),
          _ViewSection(values: s),
          const SizedBox(height: 16),
          const _DataSection(),
        ],
      ),
    );
  }
}

/// Bir nechta maydonni tahrirlab, bitta "Saqlash" bilan yozadigan forma.
class _KeyValueForm extends ConsumerStatefulWidget {
  const _KeyValueForm({required this.title, required this.fields, required this.values});
  final String title;

  /// (kalit, yorliq, raqammi, yordamchi matn)
  final List<(String, String, bool, String?)> fields;
  final Map<String, String> values;

  @override
  ConsumerState<_KeyValueForm> createState() => _KeyValueFormState();
}

class _KeyValueFormState extends ConsumerState<_KeyValueForm> {
  late final Map<String, TextEditingController> _c = {
    for (final f in widget.fields) f.$1: TextEditingController(text: widget.values[f.$1] ?? ''),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return SectionCard(
      title: widget.title,
      trailing: FilledButton.tonal(
        onPressed: () async {
          await ref.read(settingsRepoProvider).setAll({for (final e in _c.entries) e.key: e.value.text.trim()});
          if (context.mounted) showMessage(context, 'Saqlandi');
        },
        child: const Text('Saqlash'),
      ),
      child: Column(
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final f in widget.fields)
                SizedBox(
                  width: wide ? 360 : double.infinity,
                  child: TextField(
                    controller: _c[f.$1],
                    keyboardType: f.$3 ? TextInputType.number : null,
                    decoration: InputDecoration(labelText: f.$2, helperText: f.$4, helperMaxLines: 2),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StoreSection extends StatelessWidget {
  const _StoreSection({required this.values});
  final Map<String, String> values;

  @override
  Widget build(BuildContext context) => _KeyValueForm(
    title: "Do'kon va chek",
    values: values,
    fields: const [
      (SettingKeys.storeName, "Do'kon nomi", false, null),
      (SettingKeys.storeAddress, 'Manzil', false, null),
      (SettingKeys.storePhone, 'Telefon', false, null),
      (SettingKeys.storeTin, 'STIR (INN)', false, null),
      (SettingKeys.receiptFooter, 'Chek pastidagi matn', false, 'Masalan: Xaridingiz uchun rahmat!'),
      (
        SettingKeys.deviceCode,
        'Kassa (qurilma) kodi',
        false,
        'Chek raqami prefiksi: K1, K2, T1... Har bir qurilmada har xil bo\'lsin',
      ),
    ],
  );
}

class _AlertsSection extends StatelessWidget {
  const _AlertsSection({required this.values});
  final Map<String, String> values;

  @override
  Widget build(BuildContext context) => _KeyValueForm(
    title: 'Alertlar',
    values: values,
    fields: const [
      (SettingKeys.dailyTarget, "Kunlik savdo maqsadi (so'm)", true, '0 — tekshirilmaydi'),
      (SettingKeys.targetCheckHour, 'Maqsadni tekshirish soati (0–23)', true, 'Standart: 18'),
      (SettingKeys.anomalyThreshold, "Anomal chek chegarasi (so'm)", true, 'Standart: 5 000 000'),
      (SettingKeys.anomalyMultiplier, "O'rtacha chekdan necha barobar katta", true, 'Standart: 5'),
    ],
  );
}

class _ViewSection extends ConsumerWidget {
  const _ViewSection({required this.values});
  final Map<String, String> values;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(settingsRepoProvider);
    return SectionCard(
      title: "Ko'rinish",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Mavzu'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('Tizim'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: 'light', label: Text("Yorug'"), icon: Icon(Icons.light_mode)),
              ButtonSegment(value: 'dark', label: Text("Qorong'u"), icon: Icon(Icons.dark_mode)),
            ],
            selected: {values[SettingKeys.themeMode] ?? 'system'},
            onSelectionChanged: (s) => repo.set(SettingKeys.themeMode, s.first),
          ),
          const SizedBox(height: 12),
          const Text('Masshtab (yozuv va tugmalar o\'lchami)'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '1', label: Text('100%')),
              ButtonSegment(value: '0.8', label: Text('80%')),
              ButtonSegment(value: '0.7', label: Text('70%')),
            ],
            selected: {
              switch (values[SettingKeys.uiScale]) {
                '0.8' => '0.8',
                '0.7' => '0.7',
                _ => '1',
              },
            },
            onSelectionChanged: (s) => repo.set(SettingKeys.uiScale, s.first),
          ),
          const SizedBox(height: 12),
          const Text('"Tez-tez sotiladigan" davri'),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '7', label: Text('7 kun')),
              ButtonSegment(value: '30', label: Text('30 kun')),
            ],
            selected: {values[SettingKeys.frequentDays] ?? '7'},
            onSelectionChanged: (s) => repo.set(SettingKeys.frequentDays, s.first),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  Printerlar
// ============================================================================

class _PrintersSection extends ConsumerWidget {
  const _PrintersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider).value ?? const {};
    final repo = ref.read(settingsRepoProvider);
    return SectionCard(
      title: 'Printerlar (ESC/POS termoprinter)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "2 tagacha printer ulash mumkin: USB (kompyuter), Bluetooth (telefon/kompyuter) yoki Wi-Fi/LAN. "
            "Chop etish internetga bog'liq emas — offline rejimda ham ishlaydi.",
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 900;
              final cards = [const _PrinterCard(slot: 1), const _PrinterCard(slot: 2)];
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 12),
                        Expanded(child: cards[1]),
                      ],
                    )
                  : Column(children: [cards[0], const SizedBox(height: 12), cards[1]]);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Chek qayerga chiqsin:'),
              SegmentedButton<String>(
                segments: [for (final t in PrintTarget.values) ButtonSegment(value: t.code, label: Text(t.label))],
                selected: {PrintTarget.fromCode(s[SettingKeys.printMode]).code},
                onSelectionChanged: (v) => repo.set(SettingKeys.printMode, v.first),
              ),
              FilterChip(
                label: const Text("To'lovdan keyin avtomatik chop etish"),
                selected: (s[SettingKeys.autoPrint] ?? '1') == '1',
                onSelected: (v) => repo.set(SettingKeys.autoPrint, v ? '1' : '0'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PrinterCard extends ConsumerStatefulWidget {
  const _PrinterCard({required this.slot});
  final int slot;

  @override
  ConsumerState<_PrinterCard> createState() => _PrinterCardState();
}

class _PrinterCardState extends ConsumerState<_PrinterCard> {
  PrinterConfig _cfg = const PrinterConfig();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _port = TextEditingController(text: '9100');
  final _labelW = TextEditingController(text: '38');
  final _labelH = TextEditingController(text: '35');
  final _labelGap = TextEditingController(text: '2');
  bool _loaded = false;
  bool _busy = false;
  List<String> _found = [];

  @override
  void initState() {
    super.initState();
    ref.read(printerServiceProvider).config(widget.slot).then((c) {
      if (!mounted) return;
      setState(() {
        _cfg = c;
        _name.text = c.name;
        _address.text = c.address;
        _port.text = '${c.port}';
        _labelW.text = _num(c.labelWidthMm);
        _labelH.text = _num(c.labelHeightMm);
        _labelGap.text = _num(c.labelGapMm);
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _port.dispose();
    _labelW.dispose();
    _labelH.dispose();
    _labelGap.dispose();
    super.dispose();
  }

  static String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';
  static double? _mm(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));

  PrinterConfig get _current => _cfg.copyWith(
        name: _name.text.trim(),
        address: _address.text.trim(),
        port: int.tryParse(_port.text) ?? 9100,
        labelWidthMm: (_mm(_labelW) ?? 38).clamp(15, 120).toDouble(),
        labelHeightMm: (_mm(_labelH) ?? 35).clamp(10, 200).toDouble(),
        labelGapMm: (_mm(_labelGap) ?? 2).clamp(0, 10).toDouble(),
      );

  Future<void> _save() async {
    await ref.read(printerServiceProvider).saveConfig(widget.slot, _current);
    if (mounted) showMessage(context, '${widget.slot}-printer saqlandi');
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      await _save();
      await ref.read(printerServiceProvider).printTest(widget.slot);
      if (mounted) showMessage(context, 'Sinov cheki yuborildi');
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discover() async {
    setState(() => _busy = true);
    final service = ref.read(printerServiceProvider);
    try {
      if (_cfg.connection == PrinterConnection.bluetooth) {
        final list = await service.pairedBluetooth();
        _found = list.map((e) => '${e.$1}|${e.$2}').toList();
      } else if (_cfg.connection == PrinterConnection.system) {
        _found = await service.systemPrinters();
      } else if (_cfg.connection == PrinterConnection.server) {
        _found = await service.serverPrinters();
      }
      if (_found.isEmpty && mounted) {
        showMessage(
          context,
          _cfg.connection == PrinterConnection.server
              ? 'Kompyuterda printer topilmadi. Printer Windows\'ga o\'rnatilganini tekshiring.'
              : 'Printer topilmadi. Bluetooth printerni avval telefon sozlamalarida juftlang.',
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Card(
        child: SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
      );
    }
    final conn = _cfg.connection;
    final addressLabel = switch (conn) {
      PrinterConnection.network => 'IP manzil (masalan 192.168.1.100)',
      PrinterConnection.bluetooth => 'Bluetooth MAC manzil',
      PrinterConnection.system => 'Printer nomi (Windows/macOS/Linux) yoki /dev/usb/lp0',
      PrinterConnection.server => "Kompyuterdagi printer nomi (🔍 bilan tanlang)",
      PrinterConnection.none => 'Manzil',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${widget.slot}-printer', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            DropdownButtonFormField<PrinterConnection>(
              isExpanded: true,
              initialValue: conn,
              decoration: const InputDecoration(labelText: 'Ulanish turi'),
              items: [for (final c in PrinterConnection.values) DropdownMenuItem(value: c, child: Text(c.label))],
              onChanged: (v) => setState(() {
                _cfg = _cfg.copyWith(connection: v);
                _found = [];
              }),
            ),
            if (conn != PrinterConnection.none) ...[
              const SizedBox(height: 10),
              SegmentedButton<PrinterKind>(
                segments: [
                  for (final k in PrinterKind.values)
                    ButtonSegment(
                      value: k,
                      label: Text(k.title),
                      icon: Icon(k == PrinterKind.label ? Icons.label_outline : Icons.receipt_long_outlined),
                    ),
                ],
                selected: {_cfg.kind},
                onSelectionChanged: (s) => setState(() => _cfg = _cfg.copyWith(kind: s.first)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nomi (ixtiyoriy)'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      decoration: InputDecoration(labelText: addressLabel),
                    ),
                  ),
                  if (conn == PrinterConnection.network) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                  if (conn == PrinterConnection.bluetooth ||
                      conn == PrinterConnection.system ||
                      conn == PrinterConnection.server)
                    IconButton(
                      tooltip: 'Qidirish',
                      onPressed: _busy ? null : _discover,
                      icon: const Icon(Icons.search),
                    ),
                ],
              ),
              if (_found.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final f in _found)
                      ActionChip(
                        label: Text(f.contains('|') ? f.split('|').first : f),
                        onPressed: () => setState(() {
                          if (f.contains('|')) {
                            _name.text = f.split('|').first;
                            _address.text = f.split('|').last;
                          } else {
                            _address.text = f;
                          }
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 10),
              if (_cfg.kind == PrinterKind.label)
                Row(children: [
                  for (final (c, label) in [
                    (_labelW, 'Eni, mm'),
                    (_labelH, "Bo'yi, mm"),
                    (_labelGap, "Oralig'i, mm"),
                  ]) ...[
                    if (c != _labelW) const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: c,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: label),
                      ),
                    ),
                  ],
                ])
              else
                Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 58, label: Text('58 mm')),
                      ButtonSegment(value: 80, label: Text('80 mm')),
                    ],
                    selected: {_cfg.paperMm},
                    onSelectionChanged: (s) => setState(() => _cfg = _cfg.copyWith(paperMm: s.first)),
                  ),
                  DropdownButton<int>(
                    value: _cfg.copies,
                    items: [for (var i = 1; i <= 3; i++) DropdownMenuItem(value: i, child: Text('$i nusxa'))],
                    onChanged: (v) => setState(() => _cfg = _cfg.copyWith(copies: v)),
                  ),
                  FilterChip(
                    label: const Text('Qog\'ozni kesish'),
                    selected: _cfg.cut,
                    onSelected: (v) => setState(() => _cfg = _cfg.copyWith(cut: v)),
                  ),
                  FilterChip(
                    label: const Text('Pul qutisini ochish'),
                    selected: _cfg.openDrawer,
                    onSelected: (v) => setState(() => _cfg = _cfg.copyWith(openDrawer: v)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (conn != PrinterConnection.none)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: const Icon(Icons.print),
                    label: Text(_cfg.kind == PrinterKind.label ? "Sinov yorlig'i" : 'Sinov cheki'),
                  ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Saqlash')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
//  Sinxronlash
// ============================================================================

class _SyncSection extends ConsumerStatefulWidget {
  const _SyncSection({required this.values});
  final Map<String, String> values;

  @override
  ConsumerState<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends ConsumerState<_SyncSection> {
  late final _url = TextEditingController(text: widget.values[SettingKeys.syncUrl] ?? '');
  late final _key = TextEditingController(text: widget.values[SettingKeys.syncApiKey] ?? '');
  late final _interval = TextEditingController(text: widget.values[SettingKeys.syncIntervalSec] ?? '30');
  late bool _enabled = widget.values[SettingKeys.syncEnabled] == '1';
  bool _searching = false;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(settingsRepoProvider).setAll({
      SettingKeys.syncUrl: _url.text.trim(),
      SettingKeys.syncApiKey: _key.text.trim(),
      SettingKeys.syncIntervalSec: _interval.text.trim(),
      SettingKeys.syncEnabled: _enabled ? '1' : '0',
    });
    await ref.read(syncServiceProvider).start();
    if (mounted) showMessage(context, 'Sinxronlash sozlamalari saqlandi');
  }

  /// Bitta Wi-Fi'dagi PosServer'ni topib, manzilini maydonga yozadi.
  Future<void> _findServer() async {
    setState(() => _searching = true);
    final found = await ServerDiscovery.find();
    if (!mounted) return;
    setState(() => _searching = false);
    if (found.isEmpty) {
      showMessage(
        context,
        "Server topilmadi. Kompyuterda PosServer ishlayotganini va telefon bilan bitta Wi-Fi'da ekanini tekshiring.",
        error: true,
      );
      return;
    }
    var pick = found.first;
    if (found.length > 1) {
      final chosen = await showDialog<DiscoveredServer>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Serverni tanlang'),
          children: [
            for (final s in found)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, s),
                child: ListTile(title: Text(s.name.isEmpty ? s.url : s.name), subtitle: Text(s.url)),
              ),
          ],
        ),
      );
      if (chosen == null) return;
      pick = chosen;
    }
    setState(() => _url.text = pick.url);
    if (mounted) showMessage(context, "Server topildi: ${pick.url}. API kalitni yozib, 'Ulanishni tekshirish' ni bosing.");
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(syncServiceProvider);
    return SectionCard(
      title: 'Sinxronlash (bir nechta qurilma)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Har bir qurilma (notebook, telefon) o'z lokal bazasi bilan to'liq mustaqil ishlaydi. "
            "Sinxronlash serveri (FastAPI) yoqilsa, internet/tarmoq paydo bo'lganda o'zgarishlar avtomatik almashinadi. "
            "Notebook o'chiq bo'lsa ham telefon savdo qilishda davom etadi. "
            "Kompyuter IP si o'zgarsa, dastur serverni tarmoqdan o'zi qayta topadi.",
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('Sinxronlashni yoqish'),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 360,
                child: TextField(
                  controller: _url,
                  decoration: InputDecoration(
                    labelText: 'Server manzili',
                    hintText: 'http://192.168.1.10:8000',
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            tooltip: 'Serverni tarmoqdan topish',
                            icon: const Icon(Icons.wifi_find),
                            onPressed: _findServer,
                          ),
                  ),
                ),
              ),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _key,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API kalit'),
                ),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _interval,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Interval (soniya)'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<SyncStatus>(
            valueListenable: service.status,
            builder: (context, s, _) => Text(
              'Holat: ${switch (s.state) {
                SyncState.disabled => "o'chirilgan (faqat lokal)",
                SyncState.idle => 'kutilmoqda',
                SyncState.syncing => 'sinxronlanmoqda...',
                SyncState.ok => 'muvaffaqiyatli',
                SyncState.offline => 'offline',
                SyncState.error => 'xato',
              }}'
              '${s.lastSyncAt == null ? '' : ' · oxirgi: ${Fmt.dateTime(s.lastSyncAt!)}'}'
              '${s.message.isEmpty ? '' : ' · ${s.message}'}'
              ' · yuborilmagan: ${s.pending}',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton(
                onPressed: () async {
                  await _save();
                  try {
                    final msg = await service.testConnection();
                    // Ulanish ishlasa — sinxronlashni avtomatik yoqamiz (aks holda
                    // "Ulandi" chiqadi-yu, ma'lumot almashmaydi).
                    if (!_enabled) {
                      setState(() => _enabled = true);
                      await _save();
                    }
                    await service.syncNow();
                    if (context.mounted) showMessage(context, '$msg. Sinxronlash yoqildi.');
                  } catch (e) {
                    if (context.mounted) showMessage(context, e.toString(), error: true);
                  }
                },
                child: const Text('Ulanishni tekshirish'),
              ),
              OutlinedButton(
                onPressed: () async {
                  if (await confirmDialog(
                    context,
                    "To'liq qayta yuklash",
                    "Serverdagi barcha ma'lumotlar qaytadan yuklab olinadi (yangi qurilma ulanganda foydali).",
                  )) {
                    if (!_enabled) {
                      if (context.mounted) showMessage(context, "Avval 'Sinxronlashni yoqish' ni yoqing va saqlang", error: true);
                      return;
                    }
                    await service.resetCursor();
                    await service.syncNow();
                    if (context.mounted) showMessage(context, service.status.value.message);
                  }
                },
                child: const Text("Serverdan to'liq yuklash"),
              ),
              OutlinedButton(
                onPressed: () async {
                  if (!_enabled) {
                    showMessage(context, "Avval 'Sinxronlashni yoqish' ni yoqing va saqlang", error: true);
                    return;
                  }
                  await service.syncNow();
                  if (context.mounted) showMessage(context, service.status.value.message);
                },
                child: const Text('Hozir sinxronlash'),
              ),
              FilledButton(onPressed: _save, child: const Text('Saqlash')),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
//  Ma'lumotlar
// ============================================================================

class _DataSection extends ConsumerWidget {
  const _DataSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SectionCard(
      title: "Ma'lumotlar",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Zaxira nusxa olish uchun baza fayli joylashuvi.
          FutureBuilder(
            future: getApplicationSupportDirectory(),
            builder: (context, snap) => snap.hasData
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(
                      "Baza fayli: ${pth.join(snap.data!.path, 'pos_terminal.sqlite')}\n"
                      "Zaxira nusxa: ilovani yoping va shu faylni fleshka yoki bulutga nusxalang.",
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Qoldiqlarni qayta hisoblash'),
                onPressed: () async {
                  await ref.read(stockRepoProvider).recompute();
                  if (context.mounted) showMessage(context, 'Qoldiqlar harakatlar jurnalidan qayta hisoblandi');
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.eco_outlined),
                label: const Text('Mavsumiy statistikani qayta qurish'),
                onPressed: () async {
                  await ref.read(statsRepoProvider).rebuildSeasonal();
                  if (context.mounted) showMessage(context, 'Mavsumiy statistika yangilandi');
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: const Text("Demo ma'lumotlarni yuklash"),
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    "Demo ma'lumotlar",
                    "42 ta namunaviy xo'jalik tovari va ~14 oylik sotuvlar tarixi qo'shiladi. "
                        "Haqiqiy do'konda ishlatishdan oldin yangi o'rnatishda ishlating.",
                    ok: 'Yuklash',
                  );
                  if (!ok) return;
                  final admin = ref.read(authProvider)!;
                  final db = ref.read(databaseProvider);
                  final n = await DemoDataService(
                    db,
                    ref.read(settingsRepoProvider),
                    ref.read(stockRepoProvider),
                    ref.read(statsRepoProvider),
                  ).load(admin);
                  final ids = (await db.select(db.products).get()).map((p) => p.id);
                  await ref.read(alertServiceProvider).checkStock(ids);
                  if (context.mounted) showMessage(context, "$n ta demo tovar va sotuvlar tarixi qo'shildi");
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
