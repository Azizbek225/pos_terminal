/// Brauzerda (web) Windows spooler yo'q: chek brauzer yoki server orqali chiqadi.
class WindowsRawPrinter {
  static void printRaw(String printerName, List<int> data, {String docName = 'POS chek'}) =>
      throw UnsupportedError("Brauzerda Windows printeriga to'g'ridan-to'g'ri chop etib bo'lmaydi");
}
