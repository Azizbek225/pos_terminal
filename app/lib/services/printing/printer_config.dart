/// Printer ulanish turi.
enum PrinterConnection {
  none('none', "O'chirilgan"),

  /// Wi-Fi / LAN printer (ESC/POS, odatda 9100-port). Barcha platformalarda ishlaydi.
  network('network', 'Tarmoq (Wi-Fi/LAN)'),

  /// Bluetooth termoprinter (Android, iOS, macOS, Windows).
  bluetooth('bluetooth', 'Bluetooth'),

  /// Kompyuterga USB orqali ulangan va tizimga o'rnatilgan printer
  /// (Windows: spooler RAW, macOS/Linux: CUPS `lp -o raw`, yoki /dev/usb/lp0).
  system('system', 'USB / tizim printeri'),

  /// Server (PosServer.exe) turgan kompyuterga ulangan printer: telefon chekni
  /// sinxronlash serveri orqali yuboradi (Wi-Fi yoki Tailscale orqali).
  server('server', 'Kompyuter printeri (server orqali)');

  const PrinterConnection(this.code, this.label);
  final String code;
  final String label;

  static PrinterConnection fromCode(String? c) =>
      PrinterConnection.values.firstWhere((x) => x.code == c, orElse: () => PrinterConnection.none);
}

/// Bitta printer sozlamasi. Ilovada 2 ta printer slot bor (masalan:
/// 1-kassa printeri va 2-kassa printeri, yoki kassa + ombor nusxasi).
class PrinterConfig {
  const PrinterConfig({
    this.connection = PrinterConnection.none,
    this.name = '',
    this.address = '',
    this.port = 9100,
    this.paperMm = 80,
    this.copies = 1,
    this.cut = true,
    this.openDrawer = false,
    this.codeTable = 'CP866',
  });

  final PrinterConnection connection;

  /// Ko'rinadigan nom (masalan "Kassa 1 — Xprinter").
  final String name;

  /// network: IP manzil; bluetooth: MAC manzil; system: printer nomi yoki /dev/usb/lp0.
  final String address;
  final int port;

  /// Qog'oz kengligi: 58 yoki 80 mm.
  final int paperMm;
  final int copies;
  final bool cut;

  /// Naqd to'lovda pul qutisini ochish (printerga ulangan bo'lsa).
  final bool openDrawer;
  final String codeTable;

  bool get enabled => connection != PrinterConnection.none && address.trim().isNotEmpty;

  /// Bir qatordagi belgilar soni (Font A).
  int get charsPerLine => paperMm <= 58 ? 32 : 48;

  Map<String, dynamic> toJson() => {
        'connection': connection.code,
        'name': name,
        'address': address,
        'port': port,
        'paperMm': paperMm,
        'copies': copies,
        'cut': cut,
        'openDrawer': openDrawer,
        'codeTable': codeTable,
      };

  factory PrinterConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const PrinterConfig();
    return PrinterConfig(
      connection: PrinterConnection.fromCode(j['connection'] as String?),
      name: (j['name'] as String?) ?? '',
      address: (j['address'] as String?) ?? '',
      port: (j['port'] as num?)?.toInt() ?? 9100,
      paperMm: (j['paperMm'] as num?)?.toInt() ?? 80,
      copies: (j['copies'] as num?)?.toInt() ?? 1,
      cut: (j['cut'] as bool?) ?? true,
      openDrawer: (j['openDrawer'] as bool?) ?? false,
      codeTable: (j['codeTable'] as String?) ?? 'CP866',
    );
  }

  PrinterConfig copyWith({
    PrinterConnection? connection,
    String? name,
    String? address,
    int? port,
    int? paperMm,
    int? copies,
    bool? cut,
    bool? openDrawer,
  }) =>
      PrinterConfig(
        connection: connection ?? this.connection,
        name: name ?? this.name,
        address: address ?? this.address,
        port: port ?? this.port,
        paperMm: paperMm ?? this.paperMm,
        copies: copies ?? this.copies,
        cut: cut ?? this.cut,
        openDrawer: openDrawer ?? this.openDrawer,
        codeTable: codeTable,
      );
}

/// Chek qaysi printer(lar)ga chiqariladi.
enum PrintTarget {
  first('first', '1-printer'),
  second('second', '2-printer'),
  both('both', 'Ikkalasi');

  const PrintTarget(this.code, this.label);
  final String code;
  final String label;

  static PrintTarget fromCode(String? c) =>
      PrintTarget.values.firstWhere((x) => x.code == c, orElse: () => PrintTarget.first);
}
