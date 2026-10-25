import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../data/repositories/settings_repository.dart';

/// PosSetup.exe kassa ilovasini `<papka>\Kassa\` ga, PosServer.exe ni esa
/// `<papka>\` ga o'rnatadi. Shu kompyuterdagi ilova serverga o'zi ulanadi:
/// kalit server yonidagi `api_kalit.txt` dan olinadi — hech narsa yozilmaydi.
Future<void> configureLocalServer(SettingsRepository settings) async {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    if (((await settings.get(SettingKeys.syncUrl)) ?? '').trim().isNotEmpty) return;
    final installDir = p.dirname(p.dirname(Platform.resolvedExecutable));
    final keyFile = File(p.join(installDir, 'api_kalit.txt'));
    if (!keyFile.existsSync() || !File(p.join(installDir, 'PosServer.exe')).existsSync()) return;
    final key = keyFile.readAsStringSync().trim();
    if (key.isEmpty) return;
    await settings.setAll({
      SettingKeys.syncUrl: 'http://127.0.0.1:8000',
      SettingKeys.syncApiKey: key,
      SettingKeys.syncEnabled: '1',
    });
  } catch (e) {
    debugPrint('Lokal server sozlanmadi: $e');
  }
}
