import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/services/sync/server_discovery.dart';
import 'package:pos_terminal/services/sync/sync_service.dart';

import 'test_helpers.dart';

/// /api/health ga berilgan server_id bilan javob beradigan soxta server.
Future<HttpServer> fakeServer(String serverId) async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) {
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'status': 'ok', 'server_id': serverId}))
      ..close();
  });
  return srv;
}

String urlOf(HttpServer s) => 'http://127.0.0.1:${s.port}';

void main() {
  test('UDP so\'roviga javob bergan server topiladi', () async {
    final responder = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    responder.listen((e) {
      final d = responder.receive();
      if (d == null || utf8.decode(d.data) != ServerDiscovery.magic) return;
      responder.send(utf8.encode(jsonEncode({'app': 'pos-sync', 'port': 8000, 'name': 'KASSA-PC'})), d.address, d.port);
    });
    final found = await ServerDiscovery.find(
      wait: const Duration(milliseconds: 300),
      discoveryPort: responder.port,
      targets: [InternetAddress.loopbackIPv4],
    );
    responder.close();
    expect(found.map((s) => s.url), ['http://127.0.0.1:8000']);
    expect(found.single.name, 'KASSA-PC');
  });

  group('IP o\'zgarganda server qayta topiladi', () {
    late TestEnv env;
    setUp(() async {
      env = TestEnv();
      await env.settings.setAll({
        SettingKeys.syncUrl: 'http://127.0.0.1:1',
        SettingKeys.syncServerId: 'baza-1',
      });
    });

    SyncService service(List<String> urls) => SyncService(
      db: env.db,
      settings: env.settings,
      stock: env.stock,
      stats: env.stats,
      alerts: env.alerts,
      discover: () async => [for (final u in urls) DiscoveredServer(u, '')],
    );

    test('tarmoqdan topilgan o\'sha bazali server manzili saqlanadi', () async {
      final other = await fakeServer('begona');
      final ours = await fakeServer('baza-1');
      expect(await service([urlOf(other), urlOf(ours)]).relocateServer('http://127.0.0.1:1'), isTrue);
      expect(await env.settings.get(SettingKeys.syncUrl), urlOf(ours));
      await other.close(force: true);
      await ours.close(force: true);
    });

    test('begona bazali serverga o\'tilmaydi', () async {
      final other = await fakeServer('begona');
      expect(await service([urlOf(other)]).relocateServer('http://127.0.0.1:1'), isFalse);
      expect(await env.settings.get(SettingKeys.syncUrl), 'http://127.0.0.1:1');
      await other.close(force: true);
    });

    test('ilgari ishlagan manzilga (masalan Tailscale) qaytadi', () async {
      final ours = await fakeServer('baza-1');
      await env.settings.set(SettingKeys.syncKnownUrls, 'http://127.0.0.1:1\n${urlOf(ours)}');
      expect(await service(const []).relocateServer('http://127.0.0.1:1'), isTrue);
      expect(await env.settings.get(SettingKeys.syncUrl), urlOf(ours));
      await ours.close(force: true);
    });

    test('hali sinxronlanmagan qurilma avtomatik o\'tmaydi', () async {
      await env.settings.set(SettingKeys.syncServerId, '');
      final ours = await fakeServer('baza-1');
      expect(await service([urlOf(ours)]).relocateServer('http://127.0.0.1:1'), isFalse);
      await ours.close(force: true);
    });
  });
}
