/// Mavsumlarni aniqlash yordamchilari.
///
/// O'zbekiston (Shimoliy yarim shar) uchun:
/// Qish: dekabr–fevral, Bahor: mart–may, Yoz: iyun–avgust, Kuz: sentyabr–noyabr.
library;

enum Season {
  winter(0, 'winter', 'Qish', '❄️'),
  spring(1, 'spring', 'Bahor', '🌱'),
  summer(2, 'summer', 'Yoz', '☀️'),
  autumn(3, 'autumn', 'Kuz', '🍂');

  const Season(this.index0, this.code, this.label, this.emoji);

  /// DB da saqlanadigan raqamli indeks.
  final int index0;
  final String code;
  final String label;
  final String emoji;

  static Season fromIndex(int i) => Season.values.firstWhere((s) => s.index0 == i);

  static Season? fromCode(String code) {
    for (final s in Season.values) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// Berilgan sana uchun mavsum.
  static Season of(DateTime d) {
    switch (d.month) {
      case 12:
      case 1:
      case 2:
        return Season.winter;
      case 3:
      case 4:
      case 5:
        return Season.spring;
      case 6:
      case 7:
      case 8:
        return Season.summer;
      default:
        return Season.autumn;
    }
  }

  static Season get current => of(DateTime.now());

  /// Mavsumning "yili": dekabr keyingi yil qishiga tegishli bo'ladi,
  /// shunda 2025-dekabr va 2026-yanvar bitta "2026 qishi" hisoblanadi.
  static int seasonYear(DateTime d) => d.month == 12 ? d.year + 1 : d.year;

  /// Keyingi mavsum (tavsiyalarda "yaqinlashayotgan mavsum" uchun).
  Season get next => Season.fromIndex((index0 + 1) % 4);
}

/// Mahsulotning `seasonTags` maydoni vergul bilan ajratilgan kodlar
/// ko'rinishida saqlanadi: masalan "winter,autumn".
Set<Season> parseSeasonTags(String? tags) {
  if (tags == null || tags.trim().isEmpty) return {};
  return tags
      .split(',')
      .map((e) => Season.fromCode(e.trim()))
      .whereType<Season>()
      .toSet();
}

String encodeSeasonTags(Set<Season> seasons) =>
    (seasons.toList()..sort((a, b) => a.index0.compareTo(b.index0))).map((s) => s.code).join(',');
