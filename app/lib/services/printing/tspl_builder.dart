import 'dart:convert';
import 'dart:math' as math;

import '../../core/formatters.dart';
import 'label.dart';
import 'printer_config.dart';
import 'receipt_layout.dart';

/// Yorliq (etiketka) printerlari uchun TSPL buyruqlari — Xprinter XP-245B,
/// XP-365B, TSC va boshqalar. 203 dpi: 1 mm = 8 nuqta.
class TsplBuilder {
  static const _dotsPerMm = 8;

  // Ichki shriftlar: "2" — 12×20, "3" — 16×24, "4" — 24×32 nuqta.
  static const _small = ('2', 12, 20);
  static const _big = ('3', 16, 24);

  static List<int> labels(
    LabelData d,
    PrinterConfig cfg, {
    required int count,
    LabelCodeKind kind = LabelCodeKind.barcode,
    bool showName = true,
    bool showPrice = true,
  }) {
    final w = (cfg.labelWidthMm * _dotsPerMm).round();
    final h = (cfg.labelHeightMm * _dotsPerMm).round();
    const margin = 8;
    final code = d.code.trim();
    final out = StringBuffer()
      ..writeln('SIZE ${_mm(cfg.labelWidthMm)} mm,${_mm(cfg.labelHeightMm)} mm')
      ..writeln('GAP ${_mm(cfg.labelGapMm)} mm,0 mm')
      ..writeln('DIRECTION 1')
      ..writeln('REFERENCE 0,0')
      ..writeln('CLS');

    var y = margin;
    if (showName && d.name.trim().isNotEmpty) {
      final perLine = (w - 2 * margin) ~/ _small.$2;
      final lines = _wrap(_text(d.name), perLine, maxLines: h >= 200 ? 2 : 1);
      for (final line in lines) {
        out.writeln(_textCmd(line, _small, w, y));
        y += _small.$3 + 2;
      }
    }
    if (showPrice && d.price > 0) {
      out.writeln(_textCmd(_text(Fmt.money(d.price)), _big, w, y));
      y += _big.$3 + 4;
    }

    final left = h - y - margin; // kod uchun qolgan balandlik
    if (kind == LabelCodeKind.qr) {
      // QR: v2–v3 (25–29 modul); katak o'lchami joyga qarab.
      final cell = math.max(2, math.min(6, math.min(left, w - 2 * margin) ~/ 30));
      final size = 29 * cell;
      out.writeln('QRCODE ${(w - size) ~/ 2},$y,M,$cell,A,0,"${_quote(code)}"');
    } else {
      final (type, data, modules) = _barcode(code);
      final narrow = math.max(1, math.min(3, (w - 2 * margin) ~/ modules));
      final width = modules * narrow;
      const textH = 22; // kod raqamlari (human readable)
      final barH = math.max(24, math.min(120, left - textH));
      out.writeln('BARCODE ${math.max(0, (w - width) ~/ 2)},$y,"$type",$barH,1,0,$narrow,$narrow,"${_quote(data)}"');
    }
    out.writeln('PRINT ${count.clamp(1, 1000)},1');
    return latin1.encode(out.toString().replaceAll('\n', '\r\n'));
  }

  /// Sinov yorlig'i.
  static List<int> testLabel(PrinterConfig cfg) => labels(
        const LabelData(code: '2000000000015', name: 'Sinov yorlig\'i', price: 12500),
        cfg,
        count: 1,
      );

  /// (TSPL turi, ma'lumot, taxminiy modullar soni).
  static (String, String, int) _barcode(String code) {
    final digits = RegExp(r'^\d+$').hasMatch(code);
    // EAN13/EAN8 da printer nazorat raqamini o'zi qo'shadi.
    if (digits && code.length == 13) return ('EAN13', code.substring(0, 12), 95 + 18);
    if (digits && code.length == 8) return ('EAN8', code.substring(0, 7), 67 + 18);
    return ('128', code, 11 * (code.length + 3) + 2 + 20);
  }

  static String _textCmd(String s, (String, int, int) font, int labelW, int y) {
    final width = s.length * font.$2;
    final x = math.max(0, (labelW - width) ~/ 2);
    return 'TEXT $x,$y,"${font.$1}",0,1,1,"${_quote(s)}"';
  }

  static List<String> _wrap(String s, int perLine, {int maxLines = 2}) {
    final words = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final lines = <String>[];
    var cur = '';
    for (final word in words) {
      final next = cur.isEmpty ? word : '$cur $word';
      if (next.length <= perLine) {
        cur = next;
      } else {
        if (cur.isNotEmpty) lines.add(cur);
        cur = word.length > perLine ? word.substring(0, perLine) : word;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    if (lines.length > maxLines) {
      final last = lines[maxLines - 1];
      return [...lines.take(maxLines - 1), last.length >= perLine ? '${last.substring(0, perLine - 1)}.' : '$last.'];
    }
    return lines;
  }

  /// Faqat ASCII (printer shriftida o'zbek/kirill harflari yo'q).
  static String _text(String s) => ReceiptLayout.sanitize(s).replaceAll(RegExp(r'[^\x20-\x7E]'), '?');

  static String _quote(String s) => s.replaceAll('"', "'");

  static String _mm(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
