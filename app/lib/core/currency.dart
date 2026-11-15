import 'package:intl/intl.dart';

import '../data/database.dart';
import 'formatters.dart';

/// Hisob valyutasi (firma va mijoz qarzlari uchun).
enum Currency {
  uzs('UZS', "so'm"),
  usd('USD', r'$');

  const Currency(this.code, this.label);
  final String code;
  final String label;

  static Currency fromCode(String? c) => c == usd.code ? usd : uzs;
}

/// Dollar va so'm summalari bilan ishlash.
///
/// So'm — butun son (so'm). Dollar qarzlar va kirimlar bazada SENTDA (butun
/// son, 1 $ = 100) saqlanadi: yig'indilar yaxlitlash xatosisiz chiqadi.
class Money {
  Money._();

  static final _usd = NumberFormat('#,##0.00', 'en_US');

  /// 1234.5 -> "$1 234.50"
  static String usd(num dollars) {
    final neg = dollars < 0;
    final s = _usd.format(dollars.abs()).replaceAll(',', ' ');
    return '${neg ? '-' : ''}\$$s';
  }

  /// Valyutadagi summa (so'm yoki sent) -> matn.
  static String fmt(int minor, String currency) =>
      Currency.fromCode(currency) == Currency.usd ? usd(minor / 100) : Fmt.money(minor);

  /// Foydalanuvchi kiritgan son (so'm yoki dollar) -> bazadagi butun son.
  static int toMinor(double value, String currency) =>
      Currency.fromCode(currency) == Currency.usd ? (value * 100).round() : value.round();

  static double fromMinor(int minor, String currency) =>
      Currency.fromCode(currency) == Currency.usd ? minor / 100 : minor.toDouble();

  /// Dollar narxni so'mga o'tkazish: [step] so'mga YUQORIGA yaxlitlanadi
  /// (masalan 0.60 $ x 11 700 = 7 020 -> 7 100), kassa zarar ko'rmasligi uchun.
  static int usdToSum(double usd, num rate, {int step = 100}) {
    if (usd <= 0 || rate <= 0) return 0;
    final raw = usd * rate;
    if (step <= 1) return raw.round();
    // Kasr xatosi (7000.0000001) keraksiz yuqoriga sakramasligi uchun.
    return ((raw - 0.000001) / step).ceil() * step;
  }

  /// So'm -> sent (kurs bo'yicha).
  static int sumToCents(int sum, num rate) => rate <= 0 ? 0 : (sum * 100 / rate).round();

  /// Sent -> so'm (kurs bo'yicha).
  static int centsToSum(int cents, num rate) => (cents * rate / 100).round();

  /// Kurs matni: 12050.38 -> "12 050.38"
  static String rate(num r) => r == r.roundToDouble() ? Fmt.money(r, suffix: false) : _usd.format(r).replaceAll(',', ' ');
}

/// Tovar narxi ekranda: dollar narxli tovar — ikkala valyutada
/// ("$0.60 · 7 100 so'm"), qolganlari — so'mda.
String productPriceLabel(Product p) =>
    p.salePriceUsd > 0 ? '${Money.usd(p.salePriceUsd)} · ${Fmt.money(p.salePrice)}' : Fmt.money(p.salePrice);
