import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/services/printing/escpos_builder.dart';
import 'package:pos_terminal/services/printing/label.dart';
import 'package:pos_terminal/services/printing/printer_config.dart';

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
