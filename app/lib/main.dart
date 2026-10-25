
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'startup_error.dart';
import 'core/branch.dart';
import 'core/constants.dart';
import 'core/web_config.dart';
import 'data/database.dart';
import 'data/repositories/settings_repository.dart';
import 'services/notification_service.dart';
import 'services/product_images.dart';
import 'services/sync/local_server.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Kutilmagan xatolar ilovani yopib qo'ymasligi uchun — faqat jurnalga yoziladi.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('UI xatosi: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Kutilmagan xato: $error\n$stack');
    return true;
  };

  final AppDatabase db;
  final BranchContext branch;
  final NotificationService notifications;
  try {
    await initializeDateFormatting('en_US');

    // Lokal baza — internetga bog'liq emas, ilova har doim shu bilan ishlaydi.
    db = AppDatabase();
    if (kIsWeb) await _configureWeb(SettingsRepository(db));
    // PosSetup bilan o'rnatilgan Windows kassa — shu kompyuterdagi serverga o'zi ulanadi.
    await configureLocalServer(SettingsRepository(db));
    // Qurilma qaysi filialda ishlayotgani (birinchi kadrdan oldin — savdo noto'g'ri
    // filialga yozilmasligi uchun).
    final branchId = await SettingsRepository(db).get(SettingKeys.branchId);
    branch = BranchContext(branchId == null || branchId.isEmpty ? kDefaultBranchId : branchId);
    notifications = NotificationService();
    await ProductImages.init();
  } catch (e, st) {
    // Ishga tushishda xato bo'lsa (masalan baza yangilanmadi) — oyna umuman
    // ochilmay qolmasin: xatoni ekranda ko'rsatamiz va faylga yozamiz.
    debugPrint('Ishga tushish xatosi: $e\n$st');
    runApp(StartupErrorApp(error: e, stack: st, logPath: await writeStartupLog(e, st)));
    return;
  }
  try {
    await notifications.init().timeout(const Duration(seconds: 5));
  } catch (e) {
    // Bildirishnomalarsiz ham ilova ishlayveradi.
    debugPrint('Bildirishnomalar: $e');
  }

  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      branchContextProvider.overrideWithValue(branch),
      notificationServiceProvider.overrideWithValue(notifications),
    ],
    child: const PosApp(),
  ));
}

/// Brauzerda: ilova PosServer'ning o'zidan ochilgan — sinxronlash shu serverga
/// o'zi ulanadi, rasmlar to'g'ridan-to'g'ri serverga yuklanadi.
Future<void> _configureWeb(SettingsRepository settings) async {
  final cfg = webServerConfig();
  if (cfg == null) return;
  final (url, key) = cfg;
  await settings.setAll({
    SettingKeys.syncUrl: url,
    SettingKeys.syncApiKey: key,
    SettingKeys.syncEnabled: '1',
  });
  final code = (await settings.get(SettingKeys.deviceCode))?.trim() ?? '';
  if (code.isEmpty) {
    // Har bir brauzerning cheklari alohida prefiks bilan (W + qurilma ID dan).
    final id = (await settings.deviceId()).replaceAll('-', '').toUpperCase();
    await settings.set(SettingKeys.deviceCode, 'W${id.substring(id.length - 3)}');
  }
  ProductImages.webUpload = (name, bytes) async {
    final r = await http.put(
      Uri.parse('$url/api/images/${Uri.encodeComponent(name)}'),
      headers: {'X-API-Key': key, 'X-Device-Id': await settings.deviceId()},
      body: bytes,
    );
    if (r.statusCode != 200) throw Exception('Rasm serverga yuklanmadi (${r.statusCode})');
  };
}
