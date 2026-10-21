import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/formatters.dart';

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

/// Yorliq o'lchami. `perPage > 1` — A4 varaqqa to'r shaklida joylanadi,
/// aks holda har bir yorliq alohida sahifa (termo-yorliq printerlari uchun).
enum LabelSize {
  s58x40('58x40', '58 × 40 mm', 58, 40),
  s58x30('58x30', '58 × 30 mm', 58, 30),
  s40x30('40x30', '40 × 30 mm', 40, 30),
  s30x20('30x20', '30 × 20 mm', 30, 20),
  a4('a4', 'A4 varaq (3 × 8 = 24 ta)', 70, 37, columns: 3, rows: 8);

  const LabelSize(this.code, this.label, this.widthMm, this.heightMm, {this.columns = 1, this.rows = 1});
  final String code;
  final String label;
  final double widthMm;
  final double heightMm;
  final int columns;
  final int rows;

  int get perPage => columns * rows;

  PdfPageFormat get pageFormat =>
      perPage > 1 ? PdfPageFormat.a4 : PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm);

  static LabelSize fromCode(String? c) =>
      LabelSize.values.firstWhere((x) => x.code == c, orElse: () => LabelSize.s58x40);
}

/// Bitta tovar yorlig'i uchun ma'lumot.
class LabelData {
  const LabelData({required this.code, this.name = '', this.price = 0});
  final String code;
  final String name;
  final int price;
}

/// Shtrix/QR-kodli yorliqlarni PDF ko'rinishida tayyorlash. PDF tizim
/// printeriga (yorliq printeri, A4 printer yoki termoprinter drayveri) beriladi.
class LabelPdf {
  /// Kod uchun mos shtrix-kod standarti: to'g'ri EAN-13/EAN-8 bo'lsa o'shani,
  /// aks holda Code128.
  static pw.Barcode barcodeFor(String code, LabelCodeKind kind) {
    if (kind == LabelCodeKind.qr) return pw.Barcode.qrCode();
    final ean13 = pw.Barcode.ean13();
    if (code.length == 13 && ean13.isValid(code)) return ean13;
    final ean8 = pw.Barcode.ean8();
    if (code.length == 8 && ean8.isValid(code)) return ean8;
    return pw.Barcode.code128();
  }

  /// Kodni chop etib bo'ladimi (bo'sh emas, standartga to'g'ri keladi).
  static bool canEncode(String code, LabelCodeKind kind) =>
      code.trim().isNotEmpty && barcodeFor(code.trim(), kind).isValid(code.trim());

  static Future<Uint8List> build(
    LabelData data, {
    required int count,
    LabelSize size = LabelSize.s58x40,
    LabelCodeKind kind = LabelCodeKind.barcode,
    bool showName = true,
    bool showPrice = true,
  }) async {
    final font = await _font();
    final doc = pw.Document(title: data.name.isEmpty ? data.code : data.name, author: 'POS Terminal');
    final n = count.clamp(1, 1000);
    final label = _label(data, size, kind, showName, showPrice, font);

    if (size.perPage == 1) {
      final format = size.pageFormat;
      for (var i = 0; i < n; i++) {
        doc.addPage(pw.Page(pageFormat: format, margin: pw.EdgeInsets.zero, build: (_) => label));
      }
    } else {
      final w = size.widthMm * PdfPageFormat.mm, h = size.heightMm * PdfPageFormat.mm;
      for (var start = 0; start < n; start += size.perPage) {
        final onPage = (n - start).clamp(0, size.perPage);
        doc.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            margin: pw.EdgeInsets.symmetric(
              horizontal: (PdfPageFormat.a4.width - w * size.columns) / 2,
              vertical: (PdfPageFormat.a4.height - h * size.rows) / 2,
            ),
            build: (_) => pw.Wrap(
              children: [for (var i = 0; i < onPage; i++) pw.SizedBox(width: w, height: h, child: label)],
            ),
          ),
        );
      }
    }
    return doc.save();
  }

  static pw.Widget _label(
    LabelData d,
    LabelSize size,
    LabelCodeKind kind,
    bool showName,
    bool showPrice,
    pw.Font? font,
  ) {
    final small = size.heightMm <= 20;
    final pad = small ? 1.5 * PdfPageFormat.mm : 2.5 * PdfPageFormat.mm;
    final name = _clean(d.name, font);
    final style = pw.TextStyle(font: font, fontSize: small ? 6 : 8);
    final priceStyle = pw.TextStyle(font: font, fontSize: small ? 8 : 11, fontWeight: pw.FontWeight.bold);
    final barcode = barcodeFor(d.code, kind);
    final isQr = kind == LabelCodeKind.qr;

    final code = pw.BarcodeWidget(
      barcode: barcode,
      data: d.code,
      drawText: !isQr,
      textStyle: pw.TextStyle(font: font, fontSize: small ? 6 : 8),
    );

    final nameText = showName && name.isNotEmpty
        ? pw.Center(child: pw.Text(name, style: style, maxLines: small ? 1 : 2, textAlign: pw.TextAlign.center))
        : null;
    final priceText = showPrice && d.price > 0 ? pw.Text(_clean(Fmt.money(d.price), font), style: priceStyle) : null;

    return pw.Padding(
      padding: pw.EdgeInsets.all(pad),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          ?nameText,
          if (isQr)
            // QR yonida narx va kod raqami.
            pw.Expanded(
              child: pw.Row(
                children: [
                  pw.AspectRatio(aspectRatio: 1, child: code),
                  pw.SizedBox(width: pad),
                  pw.Expanded(
                    child: pw.Column(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (priceText != null) pw.FittedBox(fit: pw.BoxFit.scaleDown, child: priceText),
                        pw.FittedBox(fit: pw.BoxFit.scaleDown, child: pw.Text(d.code, style: style)),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else ...[
            if (priceText != null) pw.Center(child: priceText),
            pw.SizedBox(height: 1),
            pw.Expanded(child: pw.Padding(padding: pw.EdgeInsets.symmetric(horizontal: pad), child: code)),
          ],
        ],
      ),
    );
  }

  /// Standart PDF shrifti faqat lotin belgilarini biladi; tizim shrifti
  /// topilmasa, o'zbekcha tutuq belgilarini oddiy apostrofga almashtiramiz.
  static String _clean(String s, pw.Font? font) {
    final t = s.replaceAll(RegExp('[\u02BB\u02BC\u2018\u2019`]'), "'").replaceAll(RegExp('[\u00A0\u202F]'), ' ');
    return font == null ? t.replaceAll(RegExp(r'[^\x20-\x7E]'), '') : t;
  }

  static pw.Font? _cached;
  static bool _looked = false;

  /// Kirill va o'zbek harflari uchun tizimdagi TTF shrift (Arial yoki DejaVu).
  static Future<pw.Font?> _font() async {
    if (_looked) return _cached;
    _looked = true;
    const candidates = [
      r'C:\Windows\Fonts\arial.ttf',
      r'C:\Windows\Fonts\segoeui.ttf',
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
      '/Library/Fonts/Arial Unicode.ttf',
      '/System/Library/Fonts/Supplemental/Arial.ttf',
    ];
    for (final path in candidates) {
      try {
        final f = File(path);
        if (await f.exists()) return _cached = pw.Font.ttf((await f.readAsBytes()).buffer.asByteData());
      } catch (_) {}
    }
    return null;
  }
}
