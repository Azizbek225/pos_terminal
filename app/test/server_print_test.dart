import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/services/printing/printer_config.dart';
import 'package:pos_terminal/services/printing/printer_service.dart';

import 'test_helpers.dart';

void main() {
  test('telefon chekni server orqali kompyuter printeriga yuboradi', () async {
    final env = TestEnv();
    addTearDown(env.close);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <(String, String?, List<int>)>[];
    server.listen((req) async {
      final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      if (req.headers.value('X-API-Key') != 'k') {
        req.response.statusCode = 401;
      } else if (req.uri.path == '/api/printers') {
        req.response.write('{"printers":["XP-80C","Label"]}');
      } else if (req.uri.path == '/api/print') {
        received.add((req.uri.path, req.uri.queryParameters['printer'], body));
        req.response.write('{"printed":${body.length}}');
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));

    await env.settings.set(SettingKeys.syncUrl, 'http://127.0.0.1:${server.port}/');
    await env.settings.set(SettingKeys.syncApiKey, 'k');
    final service = PrinterService(env.settings);

    expect(await service.serverPrinters(), ['XP-80C', 'Label']);

    const cfg = PrinterConfig(connection: PrinterConnection.server, address: 'XP-80C');
    expect(cfg.enabled, isTrue);
    await service.send(cfg, [0x1B, 0x40, 65]);
    expect(received.single.$2, 'XP-80C');
    expect(received.single.$3, [0x1B, 0x40, 65]);

    await env.settings.set(SettingKeys.syncApiKey, 'xato');
    await expectLater(service.send(cfg, [1]), throwsA(isA<PrintException>()));
  });
}
