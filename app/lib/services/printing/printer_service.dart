import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../../core/constants.dart';
import '../../data/repositories/sale_repository.dart';
import '../../data/repositories/settings_repository.dart';
import 'escpos_builder.dart';
import 'label.dart';
import 'printer_config.dart';
import 'tspl_builder.dart';
import 'receipt_layout.dart';
import 'windows_raw_printer.dart';

class PrintException implements Exception {
  PrintException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bitta printerga chop etish natijasi.
class PrintResult {
  PrintResult(this.slot, this.ok, [this.error]);
  final int slot;
  final bool ok;
  final String? error;
}

/// Ikki printerni boshqaruvchi servis.
///
/// Chop etish internetga bog'liq emas — printer bevosita (USB, Bluetooth yoki
/// lokal tarmoq) orqali ulanadi, shuning uchun offline rejimda ham ishlaydi.
class PrinterService {
  PrinterService(this.settings);
  final SettingsRepository settings;

  /// Bluetooth bir vaqtda bitta ulanishni qo'llaydi — navbat bilan yuboramiz.
  Future<void> _queue = Future.value();
  String? _btMac;

  Future<PrinterConfig> config(int slot) async =>
      PrinterConfig.fromJson(await settings.getJson(slot == 1 ? SettingKeys.printer1 : SettingKeys.printer2));

  Future<void> saveConfig(int slot, PrinterConfig cfg) =>
      settings.setJson(slot == 1 ? SettingKeys.printer1 : SettingKeys.printer2, cfg.toJson());

  Future<StoreInfo> storeInfo() async {
    final s = await settings.getAll();
    return StoreInfo(
      name: (s[SettingKeys.storeName] ?? '').isEmpty ? "Xo'jalik mollari do'koni" : s[SettingKeys.storeName]!,
      address: s[SettingKeys.storeAddress] ?? '',
      phone: s[SettingKeys.storePhone] ?? '',
      tin: s[SettingKeys.storeTin] ?? '',
      footer: s[SettingKeys.receiptFooter] ?? '',
    );
  }

  Future<bool> hasAnyPrinter() async => (await config(1)).enabled || (await config(2)).enabled;

  /// Chekni chop etish. [target] berilmasa — sozlamadagi rejim ishlatiladi.
  Future<List<PrintResult>> printReceipt(SaleWithItems sale, {PrintTarget? target, bool copy = false}) async {
    final t = target ?? PrintTarget.fromCode(await settings.get(SettingKeys.printMode));
    final slots = switch (t) {
      PrintTarget.first => [1],
      PrintTarget.second => [2],
      PrintTarget.both => [1, 2],
    };
    final store = await storeInfo();
    final results = <PrintResult>[];
    for (final slot in slots) {
      final cfg = await config(slot);
      if (!cfg.enabled) {
        results.add(PrintResult(slot, false, '$slot-printer sozlanmagan'));
        continue;
      }
      if (cfg.kind == PrinterKind.label) {
        results.add(PrintResult(slot, false, '$slot-printer yorliq printeri — chek unga chiqmaydi'));
        continue;
      }
      try {
        final lines = ReceiptLayout.build(sale, store, width: cfg.charsPerLine, copy: copy);
        final drawer = cfg.openDrawer && !copy && sale.sale.paidCash > 0 &&
            sale.sale.status == SaleStatus.completed.code;
        final bytes = await EscPosBuilder.build(lines, cfg, openDrawer: drawer);
        for (var c = 0; c < cfg.copies.clamp(1, 5); c++) {
          await send(cfg, bytes);
        }
        results.add(PrintResult(slot, true));
      } catch (e) {
        results.add(PrintResult(slot, false, e.toString()));
      }
    }
    return results;
  }

  Future<void> printTest(int slot) async {
    final cfg = await config(slot);
    if (!cfg.enabled) throw PrintException('$slot-printer sozlanmagan');
    await send(cfg, cfg.kind == PrinterKind.label ? TsplBuilder.testLabel(cfg) : await EscPosBuilder.testPage(cfg));
  }

  /// Tovar yorliqlarini [slot]-printerga chop etish: yorliq printeriga TSPL,
  /// chek printeriga ESC/POS buyruqlari printerning o'z ulanishi (USB,
  /// tarmoq, Bluetooth, server) orqali yuboriladi.
  Future<void> printLabels(
    int slot,
    LabelData data, {
    required int count,
    LabelCodeKind kind = LabelCodeKind.barcode,
    bool showName = true,
    bool showPrice = true,
  }) async {
    final cfg = await config(slot);
    if (!cfg.enabled) throw PrintException('$slot-printer sozlanmagan (Sozlamalar → Printerlar)');
    final bytes = cfg.kind == PrinterKind.label
        ? TsplBuilder.labels(data, cfg, count: count, kind: kind, showName: showName, showPrice: showPrice)
        : await EscPosBuilder.labels(data, cfg,
            count: count, kind: kind, showName: showName, showPrice: showPrice);
    await send(cfg, bytes);
  }

  /// Baytlarni printerga yuborish (ulanish turiga qarab).
  Future<void> send(PrinterConfig cfg, List<int> bytes) {
    final completer = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await _sendNow(cfg, bytes).timeout(const Duration(seconds: 20));
        completer.complete();
      } on TimeoutException {
        completer.completeError(PrintException('Printer javob bermadi (timeout)'));
      } catch (e) {
        completer.completeError(e is PrintException ? e : PrintException(e.toString()));
      }
    });
    return completer.future;
  }

  Future<void> _sendNow(PrinterConfig cfg, List<int> bytes) async {
    switch (cfg.connection) {
      case PrinterConnection.none:
        throw PrintException('Printer o\'chirilgan');
      case PrinterConnection.network:
        await _sendNetwork(cfg.address.trim(), cfg.port, bytes);
      case PrinterConnection.bluetooth:
        await _sendBluetooth(cfg.address.trim(), bytes);
      case PrinterConnection.system:
        await _sendSystem(cfg.address.trim(), bytes);
      case PrinterConnection.server:
        await _sendServer(cfg.address.trim(), bytes);
    }
  }

  /// Sinxronlash serveri manzili va kalitlari (Sozlamalar → Sinxronlash).
  Future<(Uri, Map<String, String>)> _server(String path, [Map<String, String>? query]) async {
    var base = ((await settings.get(SettingKeys.syncUrl)) ?? '').trim();
    if (base.isEmpty) throw PrintException('Server manzili kiritilmagan (Sozlamalar → Sinxronlash)');
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final headers = {
      'X-API-Key': (await settings.get(SettingKeys.syncApiKey)) ?? '',
      'X-Device-Id': await settings.deviceId(),
    };
    return (Uri.parse('$base$path').replace(queryParameters: query), headers);
  }

  Future<void> _sendServer(String printer, List<int> bytes) async {
    final (uri, headers) = await _server('/api/print', {'printer': printer});
    final http.Response r;
    try {
      r = await http
          .post(uri, headers: {...headers, 'Content-Type': 'application/octet-stream'}, body: bytes)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw PrintException('Server javob bermadi');
    } catch (e) {
      throw PrintException('Serverga ulanib bo\'lmadi: $e');
    }
    if (r.statusCode == 200) return;
    if (r.statusCode == 401) throw PrintException('API kalit noto\'g\'ri (Sozlamalar → Sinxronlash)');
    if (r.statusCode == 404) throw PrintException('PosServer eski — yangi versiyasini o\'rnating');
    var detail = r.body;
    try {
      detail = (jsonDecode(r.body) as Map)['detail']?.toString() ?? detail;
    } catch (_) {}
    throw PrintException('Kompyuter printeri: $detail');
  }

  /// Server turgan kompyuterdagi printerlar nomi.
  Future<List<String>> serverPrinters() async {
    final (uri, headers) = await _server('/api/printers');
    final r = await http.get(uri, headers: headers).timeout(const Duration(seconds: 25));
    if (r.statusCode == 401) throw PrintException('API kalit noto\'g\'ri (Sozlamalar → Sinxronlash)');
    if (r.statusCode == 404) throw PrintException('PosServer eski — yangi versiyasini o\'rnating');
    if (r.statusCode != 200) throw PrintException('Server xatosi: ${r.statusCode}');
    return ((jsonDecode(r.body) as Map)['printers'] as List? ?? const []).cast<String>();
  }

  Future<void> _sendNetwork(String host, int port, List<int> bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      socket.add(bytes);
      await socket.flush();
    } on SocketException catch (e) {
      throw PrintException('Tarmoq printeriga ulanib bo\'lmadi ($host:$port): ${e.message}');
    } finally {
      await socket?.close();
      socket?.destroy();
    }
  }

  Future<void> _sendBluetooth(String mac, List<int> bytes) async {
    if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows)) {
      throw PrintException('Bu platformada Bluetooth printer qo\'llanmaydi — tarmoq yoki USB dan foydalaning');
    }
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      throw PrintException('Bluetooth yoqilmagan');
    }
    var connected = await PrintBluetoothThermal.connectionStatus;
    // Ikki Bluetooth printer bo'lsa: boshqa printerga ulangan bo'lsak — uzamiz.
    if (connected && _btMac != mac) {
      await PrintBluetoothThermal.disconnect;
      connected = false;
    }
    if (!connected) {
      connected = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (connected) _btMac = mac;
    }
    if (!connected) throw PrintException('Bluetooth printerga ulanib bo\'lmadi ($mac)');
    // Katta ma'lumotni bo'laklab yuborish — ba'zi printerlarning buferi kichik.
    const chunk = 512;
    for (var i = 0; i < bytes.length; i += chunk) {
      final ok = await PrintBluetoothThermal.writeBytes(
          bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk));
      if (!ok) throw PrintException('Bluetooth orqali yuborishda xato');
    }
  }

  Future<void> _sendSystem(String nameOrDevice, List<int> bytes) async {
    if (Platform.isWindows) {
      // FFI chaqiruvi bloklovchi, lekin chek kichik — tez bajariladi.
      WindowsRawPrinter.printRaw(nameOrDevice, bytes);
      return;
    }
    if (Platform.isLinux && nameOrDevice.startsWith('/dev/')) {
      // To'g'ridan-to'g'ri qurilma fayli (masalan /dev/usb/lp0).
      final f = File(nameOrDevice);
      await f.writeAsBytes(bytes, mode: FileMode.writeOnlyAppend, flush: true);
      return;
    }
    if (Platform.isLinux || Platform.isMacOS) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/pos_receipt_${DateTime.now().microsecondsSinceEpoch}.bin');
      await file.writeAsBytes(bytes, flush: true);
      try {
        final r = await Process.run('lp', ['-d', nameOrDevice, '-o', 'raw', file.path]);
        if (r.exitCode != 0) throw PrintException('CUPS xatosi: ${r.stderr}');
      } finally {
        unawaited(file.delete().catchError((_) => file));
      }
      return;
    }
    throw PrintException('Telefonda USB printer o\'rniga Bluetooth yoki tarmoq printeridan foydalaning');
  }

  // --------------------------------------------------------------------------
  //  Qurilmalarni topish (sozlamalar sahifasi uchun)
  // --------------------------------------------------------------------------

  /// Juftlangan Bluetooth printerlar ro'yxati: (nom, MAC).
  Future<List<(String, String)>> pairedBluetooth() async {
    try {
      final list = await PrintBluetoothThermal.pairedBluetooths;
      return list.map((b) => (b.name, b.macAdress)).toList();
    } catch (e) {
      debugPrint('Bluetooth ro\'yxati: $e');
      return [];
    }
  }

  /// Tizimga o'rnatilgan printerlar nomlari.
  Future<List<String>> systemPrinters() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run(
            'powershell', ['-NoProfile', '-Command', 'Get-Printer | Select-Object -ExpandProperty Name']);
        return (r.stdout as String).split(RegExp(r'\r?\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      if (Platform.isLinux || Platform.isMacOS) {
        final r = await Process.run('lpstat', ['-a']);
        final names = (r.stdout as String)
            .split('\n')
            .map((l) => l.split(' ').first.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        if (Platform.isLinux) {
          for (final d in ['/dev/usb/lp0', '/dev/usb/lp1']) {
            if (File(d).existsSync()) names.add(d);
          }
        }
        return names;
      }
    } catch (e) {
      debugPrint('Tizim printerlari: $e');
    }
    return [];
  }
}
