import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/database.dart';
import '../data/repositories/currency_repository.dart';
import '../data/repositories/settings_repository.dart';

/// Internetdan olingan kurs.
class FetchedRate {
  const FetchedRate(this.rate, this.date, this.source);
  final double rate;
  final String date; // YYYY-MM-DD
  final String source; // cbu | net | server
}

/// Dollar kursini avtomatik yangilash va dollar narxli tovarlarni kursga moslash.
///
/// * Kurs kuniga ikki marta olinadi: ertalab (08:00 dan keyin) va tushdan keyin
///   (14:00 dan keyin). Kassa o'sha vaqtda yopiq bo'lsa — ochilganda oladi.
/// * Manba: Markaziy bank (cbu.uz); ishlamasa — do'kon serveri (PosServer),
///   u ham bo'lmasa — open.er-api.com.
/// * Kurs bazaga yoziladi va boshqa kassalarga sinxronlanadi. Joriy kurs
///   o'zgarganda (shu kassada yoki sinxronlashdan) tovar narxlari faqat
///   yuqoriga moslanadi.
class CurrencyService {
  CurrencyService({required this.repo, required this.settings});
  final CurrencyRepository repo;
  final SettingsRepository settings;

  Timer? _timer;
  StreamSubscription<CurrencyRate?>? _sub;
  bool _fetching = false;

  /// Oxirgi xato (sozlamalarda ko'rsatish uchun).
  final lastError = ValueNotifier<String?>(null);

  static const cbuUrl = 'https://cbu.uz/uz/arkhiv-kursov-valyut/json/USD/';
  static const netUrl = 'https://open.er-api.com/v6/latest/USD';

  void start() {
    if (_sub != null) return;
    _sub = repo.watchCurrent().listen((r) async {
      if (r == null) return;
      try {
        await repo.applyRate(r.rate, step: await roundStep());
      } catch (e) {
        debugPrint('Kurs narxlarga qo\'llanmadi: $e');
      }
    });
    // Testlarda internetga chiqilmaydi va taymer qoldirilmaydi.
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) return;
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => autoFetch());
    unawaited(autoFetch());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
  }

  Future<int> roundStep() async => (await settings.getInt(SettingKeys.currencyRoundStep, 100)).clamp(1, 100000);

  /// Joriy "navbat": ertalab yoki tushdan keyin. 08:00 gacha — null (kechagi kurs).
  static String? slotOf(DateTime t) {
    if (t.hour < 8) return null;
    final d = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return t.hour >= 14 ? '$d-pm' : '$d-am';
  }

  /// Avtomatik yangilash (yoqilgan bo'lsa, shu navbatda hali olinmagan bo'lsa).
  Future<void> autoFetch() async {
    if ((await settings.get(SettingKeys.currencyAuto) ?? '1') != '1') return;
    final slot = slotOf(DateTime.now());
    if (slot == null || slot == await settings.get(SettingKeys.currencyLastSlot)) return;
    if (await refresh()) await settings.set(SettingKeys.currencyLastSlot, slot);
  }

  /// Kursni hozir olish. Qaytaradi: muvaffaqiyatli bo'ldimi.
  Future<bool> refresh() async {
    if (_fetching) return false;
    _fetching = true;
    try {
      final r = await fetchOnline();
      await repo.saveRate(
        rate: r.rate,
        source: r.source,
        rateDate: r.date,
        id: 'cbu-USD-${r.date}',
      );
      lastError.value = null;
      return true;
    } catch (e) {
      lastError.value = e.toString();
      debugPrint('Kurs olinmadi: $e');
      return false;
    } finally {
      _fetching = false;
    }
  }

  Future<FetchedRate> fetchOnline() async {
    final errors = <String>[];
    // Brauzerda cbu.uz ga to'g'ridan-to'g'ri murojaat qilib bo'lmaydi (CORS) —
    // avval do'kon serveri.
    final order = kIsWeb ? [_fromServer, _fromCbu, _fromNet] : [_fromCbu, _fromServer, _fromNet];
    for (final f in order) {
      try {
        final r = await f();
        if (r != null && r.rate > 100) return r;
      } catch (e) {
        errors.add(e.toString());
      }
    }
    throw Exception('Kurs olinmadi. Internetni tekshiring yoki kursni qo\'lda kiriting.');
  }

  Future<FetchedRate?> _fromCbu() async {
    final r = await http.get(Uri.parse(cbuUrl)).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('cbu.uz: ${r.statusCode}');
    return parseCbu(utf8.decode(r.bodyBytes));
  }

  Future<FetchedRate?> _fromServer() async {
    final url = (await settings.get(SettingKeys.syncUrl))?.trim() ?? '';
    final key = (await settings.get(SettingKeys.syncApiKey))?.trim() ?? '';
    if (url.isEmpty) return null;
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final r = await http.get(Uri.parse('$base/api/kurs'), headers: {'X-API-Key': key}).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('server: ${r.statusCode}');
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final rate = (m['rate'] as num?)?.toDouble() ?? 0;
    if (rate <= 0) return null;
    return FetchedRate(rate, (m['date'] as String?) ?? _today(), (m['source'] as String?) ?? 'server');
  }

  Future<FetchedRate?> _fromNet() async {
    final r = await http.get(Uri.parse(netUrl)).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('er-api: ${r.statusCode}');
    final m = jsonDecode(r.body) as Map<String, dynamic>;
    final rate = ((m['rates'] as Map?)?['UZS'] as num?)?.toDouble() ?? 0;
    return rate > 0 ? FetchedRate(rate, _today(), 'net') : null;
  }

  static String _today() {
    final t = DateTime.now();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  /// cbu.uz javobi: `[{"Ccy":"USD","Nominal":"1","Rate":"12050.38","Date":"14.11.2026"}]`.
  static FetchedRate? parseCbu(String body) {
    final data = jsonDecode(body);
    final rows = data is List ? data : [data];
    for (final row in rows) {
      if (row is! Map || row['Ccy'] != 'USD') continue;
      final rate = double.tryParse('${row['Rate']}'.replaceAll(',', '.')) ?? 0;
      final nominal = double.tryParse('${row['Nominal'] ?? 1}') ?? 1;
      final parts = '${row['Date'] ?? ''}'.split('.');
      final date = parts.length == 3 ? '${parts[2]}-${parts[1]}-${parts[0]}' : _today();
      if (rate > 0) return FetchedRate(rate / (nominal <= 0 ? 1 : nominal), date, 'cbu');
    }
    return null;
  }
}
