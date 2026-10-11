import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Tizim bildirishnomalari (Android, iOS, macOS, Windows, Linux).
///
/// Bildirishnoma ko'rsatib bo'lmasa (ruxsat yo'q yoki platforma qo'llamaydi)
/// xatolik yutib yuboriladi — alert baribir ilova ichida ko'rinadi.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  Future<void> init() async {
    if (kIsWeb) return;
    // Linux'da bildirishnomalar D-Bus orqali ishlaydi; sessiya avtobusi bo'lmasa
    // (masalan, xizmat sifatida ishga tushirilganda) — o'tkazib yuboramiz.
    if (Platform.isLinux && (Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? '').isEmpty) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
        linux: LinuxInitializationSettings(defaultActionName: 'Ochish'),
        windows: WindowsInitializationSettings(
          appName: 'POS Terminal',
          appUserModelId: 'Uz.PosTerminal.App',
          guid: '6f1c3a52-8e7b-4c1d-9a7e-2b5f4d3c1e90',
        ),
      );
      _ready = (await _plugin.initialize(settings: settings)) ?? false;
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('Bildirishnoma xizmati ishga tushmadi: $e');
      _ready = false;
    }
  }

  Future<void> show(String title, String body, {bool critical = false}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'pos_alerts',
            'POS ogohlantirishlari',
            channelDescription: 'Kam qoldiq, kunlik maqsad va anomal savdolar',
            importance: critical ? Importance.max : Importance.high,
            priority: critical ? Priority.max : Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
          macOS: const DarwinNotificationDetails(),
          linux: const LinuxNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('Bildirishnoma xatosi: $e');
    }
  }
}
