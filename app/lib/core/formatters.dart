import 'package:intl/intl.dart';

/// Pul, miqdor va sanalarni o'zbekcha formatlash.
///
/// Pul summalari bazada butun son (so'm) sifatida saqlanadi — tiyinlar
/// amalda ishlatilmaydi, butun son esa yaxlitlash xatolarining oldini oladi.
class Fmt {
  Fmt._();

  static final _money = NumberFormat('#,##0', 'en_US');
  static final _qty = NumberFormat('#,##0.###', 'en_US');
  static final _date = DateFormat('dd.MM.yyyy');
  static final _dateTime = DateFormat('dd.MM.yyyy HH:mm');
  static final _time = DateFormat('HH:mm');

  /// 1250000 -> "1 250 000 so'm"
  static String money(num value, {bool suffix = true}) {
    final s = _money.format(value.round()).replaceAll(',', ' ');
    return suffix ? "$s so'm" : s;
  }

  static String qty(num value) => _qty.format(value).replaceAll(',', ' ');

  static String date(DateTime d) => _date.format(d);
  static String dateTime(DateTime d) => _dateTime.format(d);
  static String time(DateTime d) => _time.format(d);

  static String dateMs(int ms) => date(DateTime.fromMillisecondsSinceEpoch(ms));
  static String dateTimeMs(int ms) => dateTime(DateTime.fromMillisecondsSinceEpoch(ms));

  static String percent(num v) => '${_qty.format(v)}%';

  /// Foydalanuvchi kiritgan matndan son ajratib olish ("1 250 000" -> 1250000).
  static double? parseNum(String input) {
    final cleaned = input.replaceAll(' ', '').replaceAll(',', '.').trim();
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  static const monthNames = [
    'Yanvar', 'Fevral', 'Mart', 'Aprel', 'May', 'Iyun',
    'Iyul', 'Avgust', 'Sentyabr', 'Oktyabr', 'Noyabr', 'Dekabr',
  ];

  static const weekdayShort = ['Du', 'Se', 'Ch', 'Pa', 'Ju', 'Sh', 'Ya'];
}

/// Kun / davr chegaralari (millisekundlarda).
class DayRange {
  DayRange(this.from, this.to);
  final DateTime from;
  final DateTime to;

  int get fromMs => from.millisecondsSinceEpoch;
  int get toMs => to.millisecondsSinceEpoch;

  static DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  static DayRange today() {
    final s = startOfDay(DateTime.now());
    return DayRange(s, s.add(const Duration(days: 1)));
  }

  static DayRange yesterday() {
    final s = startOfDay(DateTime.now()).subtract(const Duration(days: 1));
    return DayRange(s, s.add(const Duration(days: 1)));
  }

  /// Joriy hafta (dushanbadan boshlab).
  static DayRange thisWeek() {
    final now = DateTime.now();
    final s = startOfDay(now).subtract(Duration(days: now.weekday - 1));
    return DayRange(s, s.add(const Duration(days: 7)));
  }

  static DayRange thisMonth() {
    final now = DateTime.now();
    final s = DateTime(now.year, now.month, 1);
    return DayRange(s, DateTime(now.year, now.month + 1, 1));
  }

  /// Oxirgi N kun (bugun ham kiradi).
  static DayRange lastDays(int n) {
    final end = startOfDay(DateTime.now()).add(const Duration(days: 1));
    return DayRange(end.subtract(Duration(days: n)), end);
  }
}
