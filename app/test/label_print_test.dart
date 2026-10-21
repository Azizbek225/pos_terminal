import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/services/printing/escpos_builder.dart';
import 'package:pos_terminal/services/printing/label.dart';
import 'package:pos_terminal/services/printing/printer_config.dart';
import 'package:pos_terminal/services/printing/tspl_builder.dart';
import 'dart:convert';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('kodni chop etish mumkinmi', () {
    expect(LabelData.canEncode('', LabelCodeKind.barcode), isFalse);
    expect(LabelData.canEncode('2000123456782', LabelCodeKind.barcode), isTrue);
    expect(LabelData.canEncode('AB-12', LabelCodeKind.qr), isTrue);
    expect(LabelData.canEncode('Болга', LabelCodeKind.barcode), isFalse);
  });

  test('ESC/POS yorliq: shtrix (EAN-13, Code128), QR va soni', () async {
    const cfg = PrinterConfig(connection: PrinterConnection.system, address: 'XP-80C');
    const ean = LabelData(code: '2000123456782', name: "Bolg'a", price: 45000);
    final one = await EscPosBuilder.labels(ean, cfg, count: 1);
    final three = await EscPosBuilder.labels(ean, cfg, count: 3);
    expect(three.length, greaterThan(one.length * 2));
    expect(_contains(one, [0x1D, 0x6B, 2]), isTrue); // GS k: EAN-13
    final c128 = await EscPosBuilder.labels(const LabelData(code: 'AB-12'), cfg, count: 1);
    expect(_contains(c128, [0x1D, 0x6B, 73]), isTrue); // GS k: Code128
    final qr = await EscPosBuilder.labels(ean, cfg, count: 1, kind: LabelCodeKind.qr);
    expect(_contains(qr, [0x1D, 0x28, 0x6B]), isTrue); // GS ( k: QR
  });

  test('XP-245B (TSPL): 38x35 mm yorliq, EAN-13, Code128, QR va soni', () {
    const cfg = PrinterConfig(
        connection: PrinterConnection.server, address: 'Xprinter XP-245B', kind: PrinterKind.label);
    const d = LabelData(code: '2000123456782', name: "Bolg'a temir dastali 500 g", price: 45000);
    final t = latin1.decode(TsplBuilder.labels(d, cfg, count: 5));
    expect(t, contains('SIZE 38 mm,35 mm\r\n'));
    expect(t, contains('GAP 2 mm,0 mm'));
    expect(t, contains('"EAN13"'));
    expect(t, contains('"200012345678"')); // nazorat raqamini printer qo'shadi
    expect(t, contains("45 000 so'm"));
    expect(t, contains('PRINT 5,1'));
    // Barcha elementlar yorliq ichida (304 x 280 nuqta).
    for (final m in RegExp(r'^(?:TEXT|BARCODE|QRCODE) (\d+),(\d+)', multiLine: true).allMatches(t)) {
      expect(int.parse(m.group(1)!), lessThan(304));
      expect(int.parse(m.group(2)!), lessThan(280));
    }
    final c128 = latin1.decode(TsplBuilder.labels(const LabelData(code: 'AB-12'), cfg, count: 1));
    expect(c128, contains('"128"'));
    final qr = latin1.decode(TsplBuilder.labels(d, cfg, count: 1, kind: LabelCodeKind.qr));
    expect(qr, contains('QRCODE'));
    expect(qr, contains('"2000123456782"'));
  });
}

bool _contains(List<int> data, List<int> seq) {
  for (var i = 0; i + seq.length <= data.length; i++) {
    var ok = true;
    for (var j = 0; j < seq.length && ok; j++) {
      ok = data[i + j] == seq[j];
    }
    if (ok) return true;
  }
  return false;
}

void tsplTests() {}
