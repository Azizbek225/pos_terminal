import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import '../../core/formatters.dart';
import 'label_pdf.dart';
import 'printer_config.dart';
import 'receipt_layout.dart';

/// [RLine] ro'yxatini ESC/POS baytlariga aylantirish (esc_pos_utils_plus).
class EscPosBuilder {
  static CapabilityProfile? _profile;

  static Future<List<int>> build(List<RLine> lines, PrinterConfig cfg, {bool openDrawer = false}) async {
    _profile ??= await CapabilityProfile.load();
    final gen = Generator(cfg.paperMm <= 58 ? PaperSize.mm58 : PaperSize.mm80, _profile!);
    final bytes = <int>[];
    bytes.addAll(gen.reset());

    for (final l in lines) {
      if (l.isSeparator) {
        bytes.addAll(gen.hr());
        continue;
      }
      final styles = PosStyles(
        align: switch (l.align) {
          RAlign.left => PosAlign.left,
          RAlign.center => PosAlign.center,
          RAlign.right => PosAlign.right,
        },
        bold: l.bold,
        height: l.big ? PosTextSize.size2 : PosTextSize.size1,
        width: l.big ? PosTextSize.size2 : PosTextSize.size1,
      );
      bytes.addAll(gen.text(ReceiptLayout.sanitize(l.text), styles: styles));
    }
    bytes.addAll(gen.feed(3));
    if (cfg.cut) bytes.addAll(gen.cut());
    if (openDrawer) bytes.addAll(gen.drawer());
    return bytes;
  }

  /// Printerni tekshirish uchun sinov cheki.
  static Future<List<int>> testPage(PrinterConfig cfg) {
    final w = cfg.charsPerLine;
    return build([
      const RLine('SINOV CHEKI', align: RAlign.center, bold: true, big: true),
      RLine.separator,
      RLine('Printer: ${cfg.name.isEmpty ? cfg.address : cfg.name}'),
      RLine('Ulanish: ${cfg.connection.label}'),
      RLine('Qog\'oz: ${cfg.paperMm} mm, $w belgi/qator'),
      RLine('1234567890' * (w ~/ 10)),
      RLine.separator,
      const RLine("O'zbekcha: o'g'il, G'isht, Sho'rva", align: RAlign.center),
      const RLine('Printer ishlayapti!', align: RAlign.center, bold: true),
    ], cfg);
  }

  /// Termoprinter (ESC/POS) uchun yorliqlar: nom, narx va shtrix/QR-kod,
  /// har biri kesib ajratiladi.
  static Future<List<int>> labels(
    LabelData d,
    PrinterConfig cfg, {
    required int count,
    LabelCodeKind kind = LabelCodeKind.barcode,
    bool showName = true,
    bool showPrice = true,
  }) async {
    _profile ??= await CapabilityProfile.load();
    final gen = Generator(cfg.paperMm <= 58 ? PaperSize.mm58 : PaperSize.mm80, _profile!);
    final code = d.code.trim();
    final bytes = <int>[...gen.reset()];
    for (var i = 0; i < count.clamp(1, 1000); i++) {
      if (showName && d.name.isNotEmpty) {
        bytes.addAll(
          gen.text(ReceiptLayout.sanitize(d.name), styles: const PosStyles(align: PosAlign.center, bold: true)),
        );
      }
      if (showPrice && d.price > 0) {
        bytes.addAll(
          gen.text(
            ReceiptLayout.sanitize(Fmt.money(d.price)),
            styles: const PosStyles(
              align: PosAlign.center,
              bold: true,
              height: PosTextSize.size2,
              width: PosTextSize.size2,
            ),
          ),
        );
      }
      if (kind == LabelCodeKind.qr) {
        bytes.addAll(gen.qrcode(code, size: QRSize.size6));
        bytes.addAll(gen.text(code, styles: const PosStyles(align: PosAlign.center)));
      } else {
        bytes.addAll(gen.barcode(_escBarcode(code), height: 80, width: 2));
      }
      bytes.addAll(gen.feed(2));
      if (cfg.cut) bytes.addAll(gen.cut());
    }
    return bytes;
  }

  static Barcode _escBarcode(String code) {
    final digits = RegExp(r'^\d+$').hasMatch(code);
    if (digits && code.length == 13) return Barcode.ean13(code.split(''));
    if (digits && code.length == 8) return Barcode.ean8(code.split(''));
    // Code128 B to'plami: harf va raqamlar.
    return Barcode.code128('{B$code'.split(''));
  }
}
