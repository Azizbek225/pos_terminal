import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'startup_error.dart';
import 'core/branch.dart';
import 'core/constants.dart';
import 'data/database.dart';
import 'data/repositories/settings_repository.dart';
import 'services/notification_service.dart';
import 'services/product_images.dart';
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
