import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pos_terminal/services/printing/escpos_builder.dart';
import 'package:pos_terminal/services/printing/label_pdf.dart';
import 'package:pos_terminal/services/printing/printer_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('kod turi: EAN-13, EAN-8, Code128, QR', () {
    expect(LabelPdf.barcodeFor('2000123456782', LabelCodeKind.barcode).name, pw.Barcode.ean13().name);
    expect(LabelPdf.barcodeFor('96385074', LabelCodeKind.barcode).name, pw.Barcode.ean8().name);
    expect(LabelPdf.barcodeFor('ABC-123', LabelCodeKind.barcode).name, pw.Barcode.code128().name);
    expect(LabelPdf.barcodeFor('2000123456782', LabelCodeKind.qr).name, pw.Barcode.qrCode().name);
    expect(LabelPdf.canEncode('', LabelCodeKind.barcode), isFalse);
    expect(LabelPdf.canEncode("Bolg'a", LabelCodeKind.qr), isTrue);
  });

  test('yorliqlar soni bo\'yicha sahifalar', () async {
    const data = LabelData(code: '2000123456782', name: "Bolg'a 500 g", price: 45000);
    Future<int> pages(int n, LabelSize s, LabelCodeKind k) async {
      final bytes = await LabelPdf.build(data, count: n, size: s, kind: k);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      return RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(bytes)).length;
    }

    expect(await pages(5, LabelSize.s58x40, LabelCodeKind.barcode), 5);
    expect(await pages(3, LabelSize.s30x20, LabelCodeKind.qr), 3);
    expect(await pages(25, LabelSize.a4, LabelCodeKind.barcode), 2);
  });
  test('termoprinter uchun ESC/POS yorliq: shtrix, Code128 va QR', () async {
    const cfg = PrinterConfig(connection: PrinterConnection.network, address: '192.168.1.50');
    const ean = LabelData(code: '2000123456782', name: "Bolg'a", price: 45000);
    final one = await EscPosBuilder.labels(ean, cfg, count: 1);
    final three = await EscPosBuilder.labels(ean, cfg, count: 3);
    expect(three.length, greaterThan(one.length * 2));
    // GS k 2 (EAN-13) buyrug'i bor.
    expect(_contains(one, [0x1D, 0x6B, 2]), isTrue);
    final c128 = await EscPosBuilder.labels(const LabelData(code: 'AB-12'), cfg, count: 1);
    expect(_contains(c128, [0x1D, 0x6B, 73]), isTrue);
    final qr = await EscPosBuilder.labels(ean, cfg, count: 1, kind: LabelCodeKind.qr);
    expect(_contains(qr, [0x1D, 0x28, 0x6B]), isTrue);
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
