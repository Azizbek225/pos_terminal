import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../data/database.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/stats_repository.dart';
import '../../data/repositories/stock_repository.dart';
import '../../data/repositories/supplier_repository.dart' show splitImagePaths;
import '../alert_service.dart';
import '../product_images.dart';
import 'server_discovery.dart';

enum SyncState { disabled, idle, syncing, ok, offline, error }

class SyncStatus {
  const SyncStatus({this.state = SyncState.disabled, this.lastSyncAt, this.message = '', this.pending = 0});
  final SyncState state;
  final DateTime? lastSyncAt;
  final String message;
  final int pending;

  SyncStatus copyWith({SyncState? state, DateTime? lastSyncAt, String? message, int? pending}) => SyncStatus(
    state: state ?? this.state,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    message: message ?? this.message,
    pending: pending ?? this.pending,
  );
}

class SyncException implements Exception {
  SyncException(this.message, {this.offline = false});
  final String message;
  final bool offline;
  @override
  String toString() => message;
}

/// Offline-first sinxronlash.
///
/// Ishlash tartibi:
///  1. Har bir lokal o'zgarish `dirty = 1` bilan belgilanadi (internet shart emas).
///  2. PUSH: dirty yozuvlar serverga yuboriladi. Server har birini qabul qiladi
///     yoki konflikt sifatida o'z versiyasini qaytaradi.
///  3. PULL: serverdagi `seq > cursor` bo'lgan barcha o'zgarishlar olinadi va
///     lokal bazaga qo'llanadi.
///
/// Konfliktlarni hal qilish:
///  * Tovar, kategoriya, foydalanuvchi — "oxirgi yozuv yutadi" (`updated_at`;
///    teng bo'lsa `device_id` bo'yicha deterministik tanlov).
///  * Chek holati — "qaytarilgan" holati har doim ustun (qaytarish bekor bo'lmaydi).
///  * Chek qatorlari, ombor harakatlari, audit — o'zgarmas (faqat qo'shiladi),
///    shuning uchun konflikt bo'lmaydi. Qoldiq harakatlar yig'indisidan
///    hisoblanadi — ikki qurilmadagi parallel sotuvlar to'g'ri qo'shiladi.
class SyncService {
  SyncService({
    required this.db,
    required this.settings,
    required this.stock,
    required this.stats,
    required this.alerts,
    Future<List<DiscoveredServer>> Function()? discover,
  }) : discover = discover ?? ServerDiscovery.find;

  final AppDatabase db;
  final SettingsRepository settings;
  final StockRepository stock;
  final StatsRepository stats;
  final AlertService alerts;

  /// Tarmoqdan PosServer qidirish (testda almashtiriladi).
  final Future<List<DiscoveredServer>> Function() discover;

  final status = ValueNotifier(const SyncStatus());
  Timer? _timer;
  Timer? _debounce;
  bool _running = false;
  DateTime? _lastRelocate;

  /// Yangi serverga hamma narsa qayta yuborilmoqda: konflikt ogohlantirishlari
  /// bu holatda shovqin bo'ladi (server versiyasi shunchaki qabul qilinadi).
  bool _resync = false;

  static const _immutable = {
    SyncEntities.saleItems,
    SyncEntities.stockMovements,
    SyncEntities.auditLog,
    SyncEntities.supplierPurchaseItems,
  };

  TableInfo _table(String entity) => switch (entity) {
    SyncEntities.branches => db.branches,
    SyncEntities.users => db.users,
    SyncEntities.categories => db.categories,
    SyncEntities.products => db.products,
    SyncEntities.sales => db.sales,
    SyncEntities.saleItems => db.saleItems,
    SyncEntities.stockMovements => db.stockMovements,
    SyncEntities.auditLog => db.auditLog,
    SyncEntities.suppliers => db.suppliers,
    SyncEntities.supplierPurchases => db.supplierPurchases,
    SyncEntities.supplierPurchaseItems => db.supplierPurchaseItems,
    SyncEntities.supplierPayments => db.supplierPayments,
    SyncEntities.customers => db.customers,
    SyncEntities.customerDebts => db.customerDebts,
    _ => throw ArgumentError('Noma\'lum entity: $entity'),
  };

  /// Lokal, sinxronlanmaydigan ustunlar.
  static const _localOnlyColumns = {'dirty', 'stock_qty'};

  Future<void> start() async {
    _timer?.cancel();
    final enabled = (await settings.get(SettingKeys.syncEnabled)) == '1';
    final url = (await settings.get(SettingKeys.syncUrl)) ?? '';
    if (!enabled || url.isEmpty) {
      status.value = SyncStatus(state: SyncState.disabled, pending: await pendingCount());
      return;
    }
    final interval = await settings.getInt(SettingKeys.syncIntervalSec, 30);
    _timer = Timer.periodic(Duration(seconds: interval.clamp(10, 3600)), (_) => syncNow());
    unawaited(syncNow());
  }

  void dispose() {
    _timer?.cancel();
    _debounce?.cancel();
  }

  /// Savdodan keyin chaqiriladi: bir necha soniyada bitta sinxronlash.
  void requestSync() {
    if (status.value.state == SyncState.disabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), syncNow);
  }

  Future<int> pendingCount() async {
    var n = 0;
    for (final e in SyncEntities.all) {
      final row = await db
          .customSelect('SELECT COUNT(*) c FROM ${_table(e).actualTableName} WHERE dirty = 1')
          .getSingle();
      n += row.read<int>('c');
    }
    return n;
  }

  Future<void> syncNow() async {
    if (_running) return;
    final enabled = (await settings.get(SettingKeys.syncEnabled)) == '1';
    final baseUrl = ((await settings.get(SettingKeys.syncUrl)) ?? '').trim();
    if (!enabled || baseUrl.isEmpty) {
      status.value = SyncStatus(state: SyncState.disabled, pending: await pendingCount());
      return;
    }
    _running = true;
    var retry = false;
    status.value = status.value.copyWith(state: SyncState.syncing, message: 'Sinxronlanmoqda...');
    try {
      final apiKey = (await settings.get(SettingKeys.syncApiKey)) ?? '';
      final deviceId = await settings.deviceId();
      final client = _Api(baseUrl, apiKey, deviceId);
      final serverId = await _checkServer(client);
      final pushed = await _push(client, deviceId);
      final pulled = await _pull(client);
      await _syncImages(client);
      final now = DateTime.now();
      await settings.set(SettingKeys.syncLastAt, '${now.millisecondsSinceEpoch}');
      if (serverId != null) await settings.set(SettingKeys.syncServerId, serverId);
      await _rememberUrl(baseUrl);
      _resync = false;
      status.value = SyncStatus(
        state: SyncState.ok,
        lastSyncAt: now,
        message: 'Yuborildi: $pushed, olindi: $pulled',
        pending: await pendingCount(),
      );
    } on SyncException catch (e) {
      // Server javob bermadi: IP o'zgargan bo'lishi mumkin — boshqa manzilda qidiramiz.
      if (e.offline && await relocateServer(baseUrl)) {
        retry = true;
      } else {
        status.value = status.value.copyWith(
          state: e.offline ? SyncState.offline : SyncState.error,
          message: e.message,
          pending: await pendingCount(),
        );
      }
    } catch (e) {
      debugPrint('Sync xatosi: $e');
      status.value = status.value.copyWith(
        state: SyncState.error,
        message: e.toString(),
        pending: await pendingCount(),
      );
    } finally {
      _running = false;
    }
    if (retry) await syncNow();
  }

  /// Ishlagan manzilni eslab qolamiz (masalan Wi-Fi IP va Tailscale IP):
  /// biri ishlamasa, boshqasiga o'tiladi.
  Future<void> _rememberUrl(String url) async {
    final urls = await _knownUrls();
    if (urls.isNotEmpty && urls.first == url) return;
    urls
      ..remove(url)
      ..insert(0, url);
    await settings.set(SettingKeys.syncKnownUrls, urls.take(6).join('\n'));
  }

  Future<List<String>> _knownUrls() async => ((await settings.get(SettingKeys.syncKnownUrls)) ?? '')
      .split('\n')
      .map((u) => u.trim())
      .where((u) => u.isNotEmpty)
      .toList();

  /// Server eski manzilda javob bermasa: ilgari ishlagan manzillar va lokal
  /// tarmoqdan qidiruv. Faqat **o'sha bazali** server (server_id bir xil)
  /// qabul qilinadi — begona serverga tasodifan ulanib ketilmaydi.
  /// Topilsa, sozlamalardagi manzil yangilanadi va true qaytadi.
  @visibleForTesting
  Future<bool> relocateServer(String failedUrl) async {
    final now = DateTime.now();
    if (_lastRelocate != null && now.difference(_lastRelocate!) < const Duration(minutes: 1)) return false;
    _lastRelocate = now;
    final knownId = await settings.get(SettingKeys.syncServerId);
    if (knownId == null || knownId.isEmpty) return false;
    final apiKey = (await settings.get(SettingKeys.syncApiKey)) ?? '';
    final deviceId = await settings.deviceId();
    String norm(String u) => u.endsWith('/') ? u.substring(0, u.length - 1) : u;
    final tried = {norm(failedUrl)};

    Future<bool> tryUrl(String url) async {
      if (!tried.add(norm(url))) return false;
      try {
        final api = _Api(url, apiKey, deviceId, timeout: const Duration(seconds: 4));
        final r = await api.get('/api/health', const {});
        if (r['server_id'] != knownId) return false;
        await settings.set(SettingKeys.syncUrl, norm(url));
        debugPrint('Sync: server yangi manzilda topildi: $url');
        return true;
      } catch (_) {
        return false;
      }
    }

    for (final u in await _knownUrls()) {
      if (await tryUrl(u)) return true;
    }
    for (final s in await discover()) {
      if (await tryUrl(s.url)) return true;
    }
    return false;
  }

  /// Server bazasi almashganmi (yangi PosServer papkasi, qayta o'rnatish)?
  /// Almashgan bo'lsa — eski serverga yuborilgan yozuvlar yangisida yo'q:
  /// hammasini qayta yuborish uchun belgilaymiz va noldan yuklaymiz.
  Future<String?> _checkServer(_Api api) async {
    final id = (await api.get('/api/health', const {}))['server_id'] as String?;
    if (id == null || id == await settings.get(SettingKeys.syncServerId)) return id;
    for (final e in SyncEntities.all) {
      await db.customUpdate('UPDATE ${_table(e).actualTableName} SET dirty = 1', updates: {_table(e)});
    }
    await settings.set(SettingKeys.syncCursor, '0');
    _resync = true;
    return id;
  }

  // --------------------------------------------------------------------------
  //  PUSH
  // --------------------------------------------------------------------------

  /// Bitta so'rovdagi yozuvlar. Katta paket — kam so'rov; server 5000 gacha qabul qiladi.
  static const _pushBatch = 500;
  static const _pullBatch = 1000;

  /// Uzoq sinxronlashda holat qatorida jarayonni ko'rsatish.
  void _progress(String message) => status.value = status.value.copyWith(message: message);

  Future<int> _push(_Api api, String deviceId) async {
    var total = 0;
    final pending = await pendingCount();
    // Tartib muhim: avval chek, keyin uning qatorlari (FOREIGN KEY).
    for (final entity in SyncEntities.all) {
      final table = _table(entity);
      final name = table.actualTableName;
      // Keyset sahifalash: server qabul qilmagan (rejected) yozuvlar keyingi
      // sahifada qayta-qayta tanlanib, cheksiz aylanib qolmaydi.
      var lastUpdated = -1;
      var lastId = '';
      while (true) {
        final rows = await db
            .customSelect(
              'SELECT * FROM $name WHERE dirty = 1 AND (updated_at > ?1 OR (updated_at = ?1 AND id > ?2)) '
              'ORDER BY updated_at, id LIMIT $_pushBatch',
              variables: [Variable.withInt(lastUpdated), Variable.withString(lastId)],
            )
            .get();
        if (rows.isEmpty) break;
        lastUpdated = rows.last.read<int>('updated_at');
        lastId = rows.last.read<String>('id');
        final changes = rows.map((r) {
          final data = Map<String, Object?>.from(r.data)..removeWhere((k, _) => _localOnlyColumns.contains(k));
          return {
            'entity': entity,
            'id': data['id'],
            'updated_at': data['updated_at'],
            'device_id': data['device_id'],
            'data': data,
          };
        }).toList();
        final resp = await api.post('/api/sync/push', {'device_id': deviceId, 'changes': changes});

        final sentUpdated = {for (final c in changes) c['id'] as String: c['updated_at'] as int};
        final touched = <TableInfo>{};
        // Bitta tranzaksiya: yuzlab yozuvni belgilash har biri alohida diskka
        // yozilgandan o'nlab barobar tez.
        await db.transaction(() async {
          for (final a in (resp['accepted'] as List? ?? const [])) {
            final id = (a as Map)['id'] as String;
            await db.customUpdate(
              'UPDATE $name SET dirty = 0 WHERE id = ? AND updated_at = ?',
              variables: [Variable.withString(id), Variable.withInt(sentUpdated[id] ?? 0)],
            );
          }
          for (final c in (resp['conflicts'] as List? ?? const [])) {
            final m = c as Map<String, dynamic>;
            final serverData = Map<String, Object?>.from(m['data'] as Map);
            await _applyRow(entity, serverData, force: true, touched: touched);
            if (!_immutable.contains(entity) && !_resync) {
              await alerts.system(
                'Sinxronlash konflikti',
                '$entity yozuvi boshqa qurilmada yangiroq o\'zgartirilgan — server versiyasi qabul qilindi.',
                type: AlertType.sync,
                dedupeKey: 'conflict:$entity:${m['id']}',
              );
            }
          }
        });
        db.notifyUpdates({for (final t in {table, ...touched}) TableUpdate.onTable(t)});
        total += changes.length;
        _progress('Yuborilmoqda: $total / $pending');
        if (rows.length < _pushBatch) break;
      }
    }
    return total;
  }

  // --------------------------------------------------------------------------
  //  PULL
  // --------------------------------------------------------------------------

  Future<int> _pull(_Api api) async {
    var cursor = await settings.getInt(SettingKeys.syncCursor, 0);
    var total = 0;
    final touchedProducts = <String>{};
    final soldProducts = <String>{};
    final changedSales = <String>{};

    while (true) {
      final resp = await api.get('/api/sync/pull', {'since': '$cursor', 'limit': '$_pullBatch'});
      final maxSeq = (resp['max_seq'] as num?)?.toInt();
      if (maxSeq != null && cursor > maxSeq) {
        // Server bazasi yangidan boshlangan: eski kursor bilan yangi yozuvlar
        // o'tkazib yuborilardi. Noldan qayta yuklaymiz.
        cursor = 0;
        await settings.set(SettingKeys.syncCursor, '0');
        continue;
      }
      final changes = (resp['changes'] as List? ?? const []).cast<Map<String, dynamic>>();
      // Bitta sahifa ichida ham entity tartibini saqlaymiz (FK uchun).
      changes.sort((a, b) {
        final ea = SyncEntities.all.indexOf(a['entity'] as String);
        final eb = SyncEntities.all.indexOf(b['entity'] as String);
        return ea != eb ? ea.compareTo(eb) : (a['seq'] as int).compareTo(b['seq'] as int);
      });
      // Ekranlar har yozuvda emas, sahifa oxirida bir marta yangilanadi.
      final touched = <TableInfo>{};
      await db.transaction(() async {
        for (final c in changes) {
          final entity = c['entity'] as String;
          if (!SyncEntities.all.contains(entity)) continue;
          final data = Map<String, Object?>.from(c['data'] as Map);
          bool applied;
          try {
            applied = await _applyRow(entity, data, touched: touched);
          } catch (e) {
            // Bitta buzilgan yozuv butun sinxronlashni to'xtatib qo'ymasligi kerak.
            debugPrint('Sync: $entity/${data['id']} qo\'llanmadi: $e');
            await alerts.system(
              'Sinxronlash ogohlantirishi',
              '$entity yozuvini qabul qilib bo\'lmadi: $e',
              type: AlertType.sync,
              severity: AlertSeverity.warning,
              dedupeKey: 'apply:$entity:${data['id']}',
            );
            continue;
          }
          if (!applied) continue;
          if (entity == SyncEntities.stockMovements || entity == SyncEntities.products) {
            touchedProducts.add((data['product_id'] ?? data['id']) as String);
          }
          if (entity == SyncEntities.saleItems && data['product_id'] is String) {
            soldProducts.add(data['product_id'] as String);
          }
          if (entity == SyncEntities.sales) changedSales.add(data['id'] as String);
        }
      });
      if (touched.isNotEmpty) db.notifyUpdates({for (final t in touched) TableUpdate.onTable(t)});
      total += changes.length;
      cursor = (resp['cursor'] as num?)?.toInt() ?? cursor;
      await settings.set(SettingKeys.syncCursor, '$cursor');
      _progress('Olinmoqda: $total');
      if (resp['has_more'] != true) break;
    }

    if (touchedProducts.isNotEmpty) {
      await stock.recompute(touchedProducts);
      await alerts.checkStock(touchedProducts);
    }
    if (soldProducts.isNotEmpty || changedSales.isNotEmpty) {
      // Mavsumiy statistika faqat o'zgargan tovarlar bo'yicha qayta hisoblanadi
      // (har sinxronlashda millionlab chek qatorini qayta yig'masligi uchun).
      final ids = changedSales.toList();
      for (var i = 0; i < ids.length; i += 500) {
        final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
        final rows = await db
            .customSelect(
              'SELECT DISTINCT product_id FROM sale_items WHERE sale_id IN (${List.filled(chunk.length, '?').join(',')})',
              variables: chunk.map(Variable.withString).toList(),
            )
            .get();
        soldProducts.addAll(rows.map((r) => r.read<String>('product_id')));
      }
      await stats.rebuildSeasonal(productIds: soldProducts);
    }
    return total;
  }

  // --------------------------------------------------------------------------
  //  RASMLAR
  // --------------------------------------------------------------------------

  /// Tovar rasmlari va firma prays-list suratlari: bazada faqat fayl nomi
  /// bor, fayllarning o'zi alohida almashinadi. Lokalda bor, serverda yo'q — yuklanadi; serverda bor,
  /// lokalda yo'q — yuklab olinadi. Xato bo'lsa savdo sinxronlashi to'xtamaydi.
  Future<void> _syncImages(_Api api) async {
    try {
      final rows = await db
          .customSelect("SELECT DISTINCT image_path FROM products WHERE image_path <> ''")
          .get();
      final docs = await db
          .customSelect("SELECT image_paths FROM supplier_purchases WHERE image_paths <> '' AND is_deleted = 0")
          .get();
      final signs = await db
          .customSelect("SELECT signature_path FROM supplier_payments WHERE signature_path <> ''")
          .get();
      final names = <String>{
        ...rows.map((r) => r.read<String>('image_path')),
        ...signs.map((r) => r.read<String>('signature_path')),
        for (final r in docs) ...splitImagePaths(r.read<String>('image_paths')),
      }.where((n) => ProductImages.pathFor(n) != null).toSet();
      if (names.isEmpty) return;
      final onServer = ((await api.get('/api/images', const {}))['names'] as List? ?? const []).cast<String>().toSet();
      var downloaded = false;
      for (final name in names) {
        final file = File(ProductImages.pathFor(name)!);
        final local = file.existsSync();
        try {
          if (local && !onServer.contains(name)) {
            await api.putBytes('/api/images/${Uri.encodeComponent(name)}', await file.readAsBytes());
          } else if (!local && onServer.contains(name)) {
            final bytes = await api.getBytes('/api/images/${Uri.encodeComponent(name)}');
            final tmp = File('${file.path}.part');
            await tmp.writeAsBytes(bytes, flush: true);
            await tmp.rename(file.path);
            downloaded = true;
          }
        } on SyncException catch (e) {
          if (e.offline) rethrow;
          debugPrint('Rasm $name: $e');
        }
      }
      // Rasmlar ko'rinishi uchun tovar ro'yxatlarini yangilaymiz.
      if (downloaded) {
        db.notifyUpdates({TableUpdate.onTable(db.products), TableUpdate.onTable(db.supplierPurchases)});
      }
    } catch (e) {
      debugPrint('Rasmlarni sinxronlab bo\'lmadi: $e');
    }
  }

  /// Bitta yozuvni lokal bazaga qo'llash. Qaytaradi: o'zgarish kiritildimi.
  Future<bool> _applyRow(String entity, Map<String, Object?> data, {bool force = false, Set<TableInfo>? touched}) async {
    final table = _table(entity);
    final name = table.actualTableName;
    final id = data['id'] as String?;
    if (id == null) return false;
    final columns = table.$columns.map((c) => c.name).toSet();
    final incomingUpdated = (data['updated_at'] as num?)?.toInt() ?? 0;

    final local = await db
        .customSelect('SELECT * FROM $name WHERE id = ?', variables: [Variable.withString(id)])
        .getSingleOrNull();

    if (local != null && !force) {
      if (_immutable.contains(entity)) return false;
      final localDirty = local.read<int>('dirty') == 1;
      final localUpdated = local.read<int>('updated_at');
      if (entity == SyncEntities.sales &&
          local.read<String>('status') == SaleStatus.refunded.code &&
          data['status'] != SaleStatus.refunded.code) {
        // Qaytarish ustun — lokal holat saqlanadi va qayta yuboriladi.
        await db.customUpdate(
          'UPDATE sales SET dirty = 1, updated_at = ? WHERE id = ?',
          variables: [Variable.withInt(incomingUpdated + 1), Variable.withString(id)],
          updates: {db.sales},
        );
        return false;
      }
      if (localDirty && localUpdated > incomingUpdated) return false; // lokal yangiroq — keyin push qilinadi
      if (!localDirty && localUpdated == incomingUpdated) return false; // o'zgarish yo'q
    }

    if (entity == SyncEntities.users) await _resolveUsernameClash(id, data['username'] as String?);

    final values = <String, Object?>{
      for (final e in data.entries)
        if (columns.contains(e.key) && !_localOnlyColumns.contains(e.key)) e.key: _sqlValue(e.value),
      'dirty': 0,
    };
    final cols = values.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    final updates = cols.where((c) => c != 'id').map((c) => '$c = excluded.$c').join(', ');
    await db.customStatement(
      'INSERT INTO $name (${cols.join(', ')}) VALUES ($placeholders) ON CONFLICT(id) DO UPDATE SET $updates',
      cols.map((c) => values[c]).toList(),
    );
    if (touched != null) {
      touched.add(table);
    } else {
      db.notifyUpdates({TableUpdate.onTable(table)});
    }
    return true;
  }

  /// Ikki qurilmada offline holda bir xil login bilan turli xodim yaratilgan
  /// bo'lsa — lokal (boshqa ID li) xodimning loginiga qo'shimcha qo'yiladi.
  Future<void> _resolveUsernameClash(String id, String? username) async {
    if (username == null) return;
    final clash = await db
        .customSelect(
          'SELECT id FROM users WHERE username = ? AND id <> ?',
          variables: [Variable.withString(username), Variable.withString(id)],
        )
        .getSingleOrNull();
    if (clash == null) return;
    final otherId = clash.read<String>('id');
    final newName = '${username}_${otherId.substring(0, 4)}';
    await db.customUpdate(
      'UPDATE users SET username = ?, updated_at = ?, dirty = 1 WHERE id = ?',
      variables: [
        Variable.withString(newName),
        Variable.withInt(DateTime.now().millisecondsSinceEpoch),
        Variable.withString(otherId),
      ],
      updates: {db.users},
    );
    await alerts.system(
      'Login takrorlandi',
      '"$username" logini boshqa qurilmada band — lokal xodim logini "$newName" ga o\'zgartirildi.',
      type: AlertType.sync,
      severity: AlertSeverity.warning,
    );
  }

  static Object? _sqlValue(Object? v) => v is bool ? (v ? 1 : 0) : v;

  /// Serverni to'liq qayta yuklab olish (masalan yangi qurilma ulanganda).
  Future<void> resetCursor() => settings.set(SettingKeys.syncCursor, '0');

  /// PosServer'ning "/ulash" sahifasidagi QR kod: {"pos":1,"urls":[...],"key":"..."}.
  /// Noto'g'ri kod bo'lsa — null.
  static ({List<String> urls, String key})? parseConnectQr(String raw) {
    try {
      final m = jsonDecode(raw.trim());
      if (m is! Map || m['pos'] != 1) return null;
      final urls = (m['urls'] as List? ?? const []).whereType<String>().where((u) => u.startsWith('http')).toList();
      final key = m['key'];
      if (urls.isEmpty || key is! String || key.isEmpty) return null;
      return (urls: urls, key: key);
    } on FormatException {
      return null;
    }
  }

  /// Bir nechta manzildan (Wi-Fi, Tailscale) shu qurilmadan ochiladiganini
  /// topish. Hammasi bir vaqtda tekshiriladi; ro'yxat tartibida birinchisi qaytadi.
  Future<String?> firstReachable(List<String> urls) async {
    final deviceId = await settings.deviceId();
    final ok = await Future.wait(urls.map((u) async {
      try {
        await _Api(u, '', deviceId, timeout: const Duration(seconds: 5)).get('/api/health', const {});
        return true;
      } catch (_) {
        return false;
      }
    }));
    for (var i = 0; i < urls.length; i++) {
      if (ok[i]) return urls[i];
    }
    return null;
  }

  /// Serverga ulanishni tekshirish (tez: sinxronlashni kutmaydi).
  Future<String> testConnection() async {
    final baseUrl = ((await settings.get(SettingKeys.syncUrl)) ?? '').trim();
    if (baseUrl.isEmpty) throw SyncException('Server manzilini yozing (masalan http://192.168.1.10:8000)');
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      throw SyncException("Manzil http:// bilan boshlanishi kerak: http://$baseUrl");
    }
    final apiKey = (await settings.get(SettingKeys.syncApiKey)) ?? '';
    final api = _Api(baseUrl, apiKey, await settings.deviceId(), timeout: const Duration(seconds: 10));
    final Map<String, dynamic> r;
    try {
      r = await api.get('/api/health', const {});
    } on SyncException catch (e) {
      if (!e.offline) rethrow;
      throw SyncException(
        "Server javob bermadi: $baseUrl\n"
        "PosServer oynasi ochiqligini, IP to'g'riligini va telefon shu Wi-Fi yoki Tailscale'da ekanini tekshiring.",
        offline: true,
      );
    }
    // /api/health kalitsiz ochiq — kalitni tekshirish uchun bo'sh pull so'rovi yuboramiz.
    await api.get('/api/sync/pull', const {'since': '999999999999', 'limit': '1'});
    return "Ulandi: server ishlayapti (v${r['version'] ?? ''}), API kalit to'g'ri";
  }
}

/// Oddiy HTTP mijoz (API kalit va qurilma ID sarlavhalari bilan).
class _Api {
  _Api(String baseUrl, this.apiKey, this.deviceId, {this.timeout = const Duration(seconds: 20)})
    : base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  final String base;
  final String apiKey;
  final String deviceId;
  final Duration timeout;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-API-Key': apiKey,
    'X-Device-Id': deviceId,
  };

  Future<Map<String, dynamic>> get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$base$path').replace(queryParameters: query.isEmpty ? null : query);
    return _handle(() => http.get(uri, headers: _headers).timeout(timeout));
  }

  Future<Map<String, dynamic>> post(String path, Object body) async {
    final uri = Uri.parse('$base$path');
    return _handle(() => http.post(uri, headers: _headers, body: jsonEncode(body)).timeout(timeout));
  }

  Future<void> putBytes(String path, List<int> bytes) async {
    final uri = Uri.parse('$base$path');
    final headers = {..._headers, 'Content-Type': 'application/octet-stream'};
    await _send(() => http.put(uri, headers: headers, body: bytes).timeout(const Duration(seconds: 60)));
  }

  Future<List<int>> getBytes(String path) async {
    final uri = Uri.parse('$base$path');
    final r = await _send(() => http.get(uri, headers: _headers).timeout(const Duration(seconds: 60)));
    return r.bodyBytes;
  }

  Future<Map<String, dynamic>> _handle(Future<http.Response> Function() call) async {
    final r = await _send(call);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    http.Response r;
    try {
      r = await call();
    } on TimeoutException {
      throw SyncException('Server javob bermadi (offline rejim)', offline: true);
    } catch (e) {
      throw SyncException('Server bilan aloqa yo\'q — offline rejimda ishlanmoqda', offline: true);
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw SyncException('API kalit noto\'g\'ri');
    }
    if (r.statusCode >= 400) {
      throw SyncException('Server xatosi ${r.statusCode}: ${r.body.length > 200 ? r.body.substring(0, 200) : r.body}');
    }
    return r;
  }
}
