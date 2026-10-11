import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'data/database.dart';
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

  await initializeDateFormatting('en_US');

  // Lokal baza — internetga bog'liq emas, ilova har doim shu bilan ishlaydi.
  final db = AppDatabase();
  final notifications = NotificationService();
  await notifications.init();
  await ProductImages.init();

  runApp(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(notifications),
    ],
    child: const PosApp(),
  ));
}
