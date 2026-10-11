import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/security.dart';
import '../database.dart';

/// Sozlama kalitlari — bir joyda saqlanadi, xato yozilishining oldini oladi.
class SettingKeys {
  static const storeName = 'store.name';
  static const storeAddress = 'store.address';
  static const storePhone = 'store.phone';
  static const storeTin = 'store.tin'; // STIR (INN)
  static const receiptFooter = 'receipt.footer';
  static const receiptSeq = 'receipt.seq';

  static const deviceId = 'device.id';
  static const deviceCode = 'device.code'; // Chek raqami prefiksi: K1, K2, T1...

  static const dailyTarget = 'target.daily';
  static const targetCheckHour = 'target.checkHour';
  static const anomalyThreshold = 'anomaly.threshold';
  static const anomalyMultiplier = 'anomaly.multiplier';

  static const printer1 = 'printer.1';
  static const printer2 = 'printer.2';
  static const printMode = 'printer.mode'; // first | second | both
  static const autoPrint = 'printer.auto';

  static const syncUrl = 'sync.url';
  static const syncApiKey = 'sync.apiKey';
  static const syncEnabled = 'sync.enabled';
  static const syncCursor = 'sync.cursor';
  static const syncLastAt = 'sync.lastAt';
  static const syncServerId = 'sync.serverId'; // Oxirgi sinxronlangan server bazasi ID si
  static const syncIntervalSec = 'sync.intervalSec';

  static const themeMode = 'ui.theme'; // system | light | dark
  static const frequentDays = 'ui.frequentDays'; // 7 | 30
}

class SettingsRepository {
  SettingsRepository(this.db);
  final AppDatabase db;

  Future<String?> get(String key) async {
    final row = await (db.select(db.settings)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) =>
      db.into(db.settings).insertOnConflictUpdate(SettingsCompanion.insert(key: key, value: value));

  Future<void> setAll(Map<String, String> values) => db.batch((b) {
        for (final e in values.entries) {
          b.insert(db.settings, SettingsCompanion.insert(key: e.key, value: e.value),
              mode: InsertMode.insertOrReplace);
        }
      });

  /// Barcha sozlamalarni Map ko'rinishida kuzatish (UI real-time yangilanadi).
  Stream<Map<String, String>> watchAll() =>
      db.select(db.settings).watch().map((rows) => {for (final r in rows) r.key: r.value});

  Future<Map<String, String>> getAll() async =>
      {for (final r in await db.select(db.settings).get()) r.key: r.value};

  Future<int> getInt(String key, int def) async => int.tryParse(await get(key) ?? '') ?? def;

  Future<Map<String, dynamic>?> getJson(String key) async {
    final s = await get(key);
    if (s == null || s.isEmpty) return null;
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> setJson(String key, Map<String, dynamic> value) => set(key, jsonEncode(value));

  /// Qurilmaning doimiy noyob ID si (birinchi chaqiruvda yaratiladi).
  Future<String> deviceId() async {
    var id = await get(SettingKeys.deviceId);
    if (id == null || id.isEmpty) {
      id = Ids.newId();
      await set(SettingKeys.deviceId, id);
    }
    return id;
  }

  /// Keyingi chek raqami: "QURILMA_KODI-000123" (6 xonali tartib raqami).
  /// Tranzaksiya ichida chaqirilishi kerak.
  Future<String> nextReceiptNo() async {
    final code = (await get(SettingKeys.deviceCode))?.trim();
    final seq = await getInt(SettingKeys.receiptSeq, 0) + 1;
    await set(SettingKeys.receiptSeq, '$seq');
    final prefix = (code == null || code.isEmpty) ? 'K1' : code;
    return '$prefix-${seq.toString().padLeft(6, '0')}';
  }
}
