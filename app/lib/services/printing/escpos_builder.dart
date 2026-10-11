import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

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
}
