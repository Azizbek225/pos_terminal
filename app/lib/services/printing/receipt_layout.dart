import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/repositories/sale_repository.dart';

/// Chekning platformaga bog'liq bo'lmagan ko'rinishi.
///
/// Bitta maket ham ekrandagi ko'rinish (preview), ham ESC/POS printer uchun
/// ishlatiladi — shuning uchun ekranda ko'rgan narsangiz qog'ozga aynan chiqadi.
enum RAlign { left, center, right }

class RLine {
  const RLine(this.text, {this.align = RAlign.left, this.bold = false, this.big = false});
  final String text;
  final RAlign align;
  final bool bold;

  /// Ikki barobar o'lcham (sarlavha va JAMI uchun).
  final bool big;

  /// Ajratuvchi chiziq.
  static const separator = RLine('\u0000sep');
  bool get isSeparator => text == '\u0000sep';
}

class StoreInfo {
  const StoreInfo({this.name = "Xo'jalik mollari", this.address = '', this.phone = '', this.tin = '', this.footer = ''});
  final String name;
  final String address;
  final String phone;
  final String tin;
  final String footer;
}

class ReceiptLayout {
  /// [width] — bir qatordagi belgilar soni (58mm ≈ 32, 80mm ≈ 48).
  static List<RLine> build(SaleWithItems s, StoreInfo store, {int width = 48, bool copy = false}) {
    final sale = s.sale;
    final lines = <RLine>[];
    lines.add(RLine(store.name, align: RAlign.center, bold: true, big: true));
    if (store.address.isNotEmpty) lines.add(RLine(store.address, align: RAlign.center));
    if (store.phone.isNotEmpty) lines.add(RLine('Tel: ${store.phone}', align: RAlign.center));
    if (store.tin.isNotEmpty) lines.add(RLine('STIR: ${store.tin}', align: RAlign.center));
    if (copy) lines.add(const RLine('*** NUSXA ***', align: RAlign.center, bold: true));
    if (sale.status == SaleStatus.refunded.code) {
      lines.add(const RLine('*** QAYTARILGAN ***', align: RAlign.center, bold: true));
    }
    lines.add(RLine.separator);
    lines.add(RLine(_lr('Chek:', sale.receiptNo, width)));
    lines.add(RLine(_lr('Sana:', Fmt.dateTimeMs(sale.createdAt), width)));
    lines.add(RLine(_lr('Kassir:', sale.cashierName, width)));
    lines.add(RLine.separator);

    for (var i = 0; i < s.items.length; i++) {
      final it = s.items[i];
      for (final part in _wrap('${i + 1}. ${it.productName}', width)) {
        lines.add(RLine(part));
      }
      final left = '   ${Fmt.qty(it.qty)} ${it.unit} x ${Fmt.money(it.price, suffix: false)}';
      lines.add(RLine(_lr(left, Fmt.money(it.qty * it.price, suffix: false), width)));
      if (it.discountAmount > 0) {
        lines.add(RLine(_lr('   Chegirma', '-${Fmt.money(it.discountAmount, suffix: false)}', width)));
      }
    }
    lines.add(RLine.separator);
    lines.add(RLine(_lr('Oraliq jami:', Fmt.money(sale.subtotal), width)));
    if (sale.discountAmount > 0) {
      final pct = sale.discountType == 'percent' ? ' (${Fmt.qty(sale.discountValue)}%)' : '';
      lines.add(RLine(_lr('Chegirma$pct:', '-${Fmt.money(sale.discountAmount)}', width)));
    }
    // JAMI — katta shriftda yarim kenglik.
    lines.add(RLine(_lr('JAMI:', Fmt.money(sale.total), width ~/ 2), bold: true, big: true));
    lines.add(RLine.separator);
    lines.add(RLine(_lr("To'lov turi:", PaymentType.fromCode(sale.paymentType).label, width)));
    if (sale.paidCash > 0) lines.add(RLine(_lr('Naqd:', Fmt.money(sale.paidCash), width)));
    if (sale.paidCard > 0) lines.add(RLine(_lr('Karta:', Fmt.money(sale.paidCard), width)));
    if (sale.paidTransfer > 0) lines.add(RLine(_lr("O'tkazma:", Fmt.money(sale.paidTransfer), width)));
    if (sale.debtAmount > 0) {
      lines.add(RLine(_lr('Nasiyaga (qarz):', Fmt.money(sale.debtAmount), width), bold: true));
      if (sale.customerName.isNotEmpty) lines.add(RLine(_lr('Mijoz:', sale.customerName, width)));
    }
    if (sale.changeAmount > 0) lines.add(RLine(_lr('Qaytim:', Fmt.money(sale.changeAmount), width), bold: true));
    lines.add(RLine(_lr('Tovarlar soni:', Fmt.qty(sale.itemCount), width)));
    lines.add(RLine.separator);
    lines.add(RLine(store.footer.isEmpty ? 'Xaridingiz uchun rahmat!' : store.footer, align: RAlign.center));
    return lines;
  }

  /// Chap va o'ng matnni bitta qatorga joylash.
  static String _lr(String l, String r, int width) {
    final space = width - l.length - r.length;
    if (space >= 1) return l + ' ' * space + r;
    // Sig'masa — chap qismni qisqartiramiz.
    final maxL = (width - r.length - 1).clamp(0, l.length);
    return '${l.substring(0, maxL)} $r';
  }

  static List<String> _wrap(String text, int width) {
    final out = <String>[];
    var rest = text;
    while (rest.length > width) {
      var cut = rest.lastIndexOf(' ', width);
      if (cut <= 0) cut = width;
      out.add(rest.substring(0, cut));
      rest = '   ${rest.substring(cut).trimLeft()}';
    }
    out.add(rest);
    return out;
  }

  /// Printerlar odatda faqat CP866/CP1252 kabi bir baytli kodlashni qo'llaydi.
  /// O'zbek lotin alifbosidagi maxsus apostroflarni oddiy ' ga almashtiramiz.
  static String sanitize(String s) {
    const map = {
      '‘': "'", '’': "'", 'ʻ': "'", 'ʼ': "'", '`': "'",
      '“': '"', '”': '"', '–': '-', '—': '-', '№': 'N',
      ' ': ' ', '•': '*',
    };
    final b = StringBuffer();
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      final m = map[c];
      if (m != null) {
        b.write(m);
      } else if (ch < 128) {
        b.write(c);
      } else {
        b.write(_translit[c] ?? '?');
      }
    }
    return b.toString();
  }

  /// Kirill harflari uchun oddiy transliteratsiya (tovar nomi kirillda bo'lsa).
  static const _translit = {
    'А': 'A', 'Б': 'B', 'В': 'V', 'Г': 'G', 'Д': 'D', 'Е': 'E', 'Ё': 'Yo', 'Ж': 'J', 'З': 'Z', 'И': 'I',
    'Й': 'Y', 'К': 'K', 'Л': 'L', 'М': 'M', 'Н': 'N', 'О': 'O', 'П': 'P', 'Р': 'R', 'С': 'S', 'Т': 'T',
    'У': 'U', 'Ф': 'F', 'Х': 'X', 'Ц': 'S', 'Ч': 'Ch', 'Ш': 'Sh', 'Щ': 'Sh', 'Ъ': "'", 'Ы': 'I', 'Ь': '',
    'Э': 'E', 'Ю': 'Yu', 'Я': 'Ya', 'Ў': "O'", 'Қ': 'Q', 'Ғ': "G'", 'Ҳ': 'H',
    'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo', 'ж': 'j', 'з': 'z', 'и': 'i',
    'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm', 'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't',
    'у': 'u', 'ф': 'f', 'х': 'x', 'ц': 's', 'ч': 'ch', 'ш': 'sh', 'щ': 'sh', 'ъ': "'", 'ы': 'i', 'ь': '',
    'э': 'e', 'ю': 'yu', 'я': 'ya', 'ў': "o'", 'қ': 'q', 'ғ': "g'", 'ҳ': 'h',
  };
}
