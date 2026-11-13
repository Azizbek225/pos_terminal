import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/services/sync/sync_service.dart';

void main() {
  const payload = {
    'pos': 1,
    'urls': ['http://192.168.1.5:8000', 'https://kassa.tail1.ts.net'],
    'key': 'abc123',
  };

  test('oddiy JSON QR', () {
    final qr = SyncService.parseConnectQr(jsonEncode(payload));
    expect(qr?.key, 'abc123');
    expect(qr?.urls.length, 2);
  });

  test("telefonga o'rnatish QR i (havola + #pos=)", () {
    // Server: quote(payload, safe=':/,')
    final enc = Uri.encodeComponent(jsonEncode(payload)).replaceAll('%3A', ':').replaceAll('%2F', '/').replaceAll('%2C', ',');
    final qr = SyncService.parseConnectQr('http://192.168.1.5:8000/telefon#pos=$enc');
    expect(qr?.key, 'abc123');
    expect(qr?.urls.first, 'http://192.168.1.5:8000');
  });

  test('begona QR', () {
    expect(SyncService.parseConnectQr('https://example.com'), isNull);
    expect(SyncService.parseConnectQr('http://x/telefon#pos=%E0%A4%A'), isNull);
  });
}
