import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../data/repositories/settings_repository.dart';

/// PosSetup.exe kassa ilovasini `<papka>\Kassa\` ga, PosServer.exe ni esa
/// `<papka>\` ga o'rnatadi. Shu kompyuterdagi kassa server bilan bitta dastur
/// kabi ishlaydi: serverni o'zi yoqadi va unga o'zi ulanadi.
String? _installDir() {
  if (kIsWeb || !Platform.isWindows) return null;
  final dir = p.dirname(p.dirname(Platform.resolvedExecutable));
  return File(p.join(dir, 'PosServer.exe')).existsSync() ? dir : null;
}

/// Shu kompyuterda PosSetup bilan o'rnatilgan server bormi.
bool get hasLocalServer => _installDir() != null;

const localServerUrl = 'http://127.0.0.1:8000';

/// Kalit server yonidagi `api_kalit.txt` dan olinadi — hech narsa yozilmaydi.
Future<void> configureLocalServer(SettingsRepository settings) async {
  final dir = _installDir();
  if (dir == null) return;
  try {
    if (((await settings.get(SettingKeys.syncUrl)) ?? '').trim().isNotEmpty) return;
    final keyFile = File(p.join(dir, 'api_kalit.txt'));
    if (!keyFile.existsSync()) return;
    final key = keyFile.readAsStringSync().trim();
    if (key.isEmpty) return;
    await settings.setAll({
      SettingKeys.syncUrl: localServerUrl,
      SettingKeys.syncApiKey: key,
      SettingKeys.syncEnabled: '1',
    });
  } catch (e) {
    debugPrint('Lokal server sozlanmadi: $e');
  }
}

/// Server ishlamayotgan bo'lsa — fonda (oynasiz) yoqib qo'yadi. Kassa bilan
/// bitta belgi: foydalanuvchi serverni alohida ishga tushirmaydi.
Future<void> startLocalServer() async {
  final dir = _installDir();
  if (dir == null) return;
  try {
    final s = await Socket.connect('127.0.0.1', 8000, timeout: const Duration(seconds: 1));
    s.destroy();
    return; // allaqachon ishlayapti
  } catch (_) {}
  try {
    await Process.start(p.join(dir, 'PosServer.exe'), const ['--minimized'],
        workingDirectory: dir, mode: ProcessStartMode.detached);
  } catch (e) {
    debugPrint('Server ishga tushmadi: $e');
  }
}

/// Telefonni ulash va internet sahifasi (QR, Tailscale ustasi) — brauzerda.
Future<void> openServerPanel() async {
  if (kIsWeb || !Platform.isWindows) return;
  await Process.start('explorer.exe', ['http://localhost:8000/ulash'], mode: ProcessStartMode.detached);
}
