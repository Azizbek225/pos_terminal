import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Windows spooler orqali printerga "RAW" ma'lumot yuborish.
///
/// USB termoprinter Windows'da odatda drayver bilan o'rnatiladi (masalan
/// "XP-80C"). ESC/POS baytlarini drayver o'zgartirmasligi uchun RAW
/// rejimida WritePrinter ishlatamiz. Kod faqat Windows'da chaqiriladi.
final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

typedef _OpenPrinterC = Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _OpenPrinterD = int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>);
typedef _StartDocC = Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>);
typedef _StartDocD = int Function(int, int, Pointer<_DocInfo1>);
typedef _HandleC = Int32 Function(IntPtr);
typedef _HandleD = int Function(int);
typedef _WriteC = Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>);
typedef _WriteD = int Function(int, Pointer<Uint8>, int, Pointer<Uint32>);

class WindowsRawPrinter {
  static DynamicLibrary? _lib;
  static DynamicLibrary get _winspool => _lib ??= DynamicLibrary.open('winspool.drv');

  static void printRaw(String printerName, List<int> data, {String docName = 'POS chek'}) {
    final openPrinter = _winspool.lookupFunction<_OpenPrinterC, _OpenPrinterD>('OpenPrinterW');
    final startDoc = _winspool.lookupFunction<_StartDocC, _StartDocD>('StartDocPrinterW');
    final startPage = _winspool.lookupFunction<_HandleC, _HandleD>('StartPagePrinter');
    final write = _winspool.lookupFunction<_WriteC, _WriteD>('WritePrinter');
    final endPage = _winspool.lookupFunction<_HandleC, _HandleD>('EndPagePrinter');
    final endDoc = _winspool.lookupFunction<_HandleC, _HandleD>('EndDocPrinter');
    final closePrinter = _winspool.lookupFunction<_HandleC, _HandleD>('ClosePrinter');

    final name = printerName.toNativeUtf16();
    final handlePtr = calloc<IntPtr>();
    final doc = calloc<_DocInfo1>();
    final docNamePtr = docName.toNativeUtf16();
    final rawPtr = 'RAW'.toNativeUtf16();
    final buf = calloc<Uint8>(data.length);
    final written = calloc<Uint32>();
    try {
      if (openPrinter(name, handlePtr, nullptr) == 0) {
        throw Exception('Printer topilmadi: "$printerName"');
      }
      final h = handlePtr.value;
      try {
        doc.ref
          ..pDocName = docNamePtr
          ..pOutputFile = nullptr
          ..pDatatype = rawPtr;
        if (startDoc(h, 1, doc) == 0) throw Exception('StartDocPrinter xatosi');
        startPage(h);
        buf.asTypedList(data.length).setAll(0, data);
        final ok = write(h, buf, data.length, written);
        endPage(h);
        endDoc(h);
        if (ok == 0 || written.value != data.length) {
          throw Exception('Printerga yozib bo\'lmadi (${written.value}/${data.length})');
        }
      } finally {
        closePrinter(h);
      }
    } finally {
      calloc
        ..free(name)
        ..free(handlePtr)
        ..free(doc)
        ..free(docNamePtr)
        ..free(rawPtr)
        ..free(buf)
        ..free(written);
    }
  }
}
