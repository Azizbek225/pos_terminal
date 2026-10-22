/// Yorliqdagi kod turi.
enum LabelCodeKind {
  barcode('barcode', 'Shtrix-kod'),
  qr('qr', 'QR-kod');

  const LabelCodeKind(this.code, this.label);
  final String code;
  final String label;

  static LabelCodeKind fromCode(String? c) =>
      LabelCodeKind.values.firstWhere((x) => x.code == c, orElse: () => LabelCodeKind.barcode);
}

/// Bitta tovar yorlig'i uchun ma'lumot.
class LabelData {
  const LabelData({required this.code, this.name = '', this.price = 0});
  final String code;
  final String name;
  final int price;

  /// Kodni printer chop eta oladimi: bo'sh emas, faqat lotin harf/raqam/belgilar.
  static bool canEncode(String code, LabelCodeKind kind) {
    final c = code.trim();
    return c.isNotEmpty && c.length <= 200 && RegExp(r'^[\x20-\x7E]+$').hasMatch(c);
  }
}
