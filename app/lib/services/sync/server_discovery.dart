import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Tarmoqda topilgan PosServer.
class DiscoveredServer {
  const DiscoveredServer(this.url, this.name);
  final String url;
  final String name;
}

/// PosServer'ni lokal tarmoqdan topish (UDP broadcast).
///
/// Telefon "POS_DISCOVER" deb tarmoqqa so'raydi, PosServer o'z porti bilan
/// javob beradi. Javob kelgan manzil — kompyuterning hozirgi IP si. Shu
/// tufayli router kompyuterga yangi IP bersa ham server qayta topiladi.
class ServerDiscovery {
  static const port = 8765;
  static const magic = 'POS_DISCOVER';

  static Future<List<DiscoveredServer>> find({
    Duration wait = const Duration(seconds: 2),
    int discoveryPort = port,
    List<InternetAddress>? targets,
  }) async {
    // Brauzerda UDP yo'q (web ilova serverning o'zidan ochiladi).
    if (kIsWeb) return const [];
    final found = <String, DiscoveredServer>{};
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final s = sock;
      final sub = s.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        try {
          final m = jsonDecode(utf8.decode(d.data));
          if (m is Map && m['app'] == 'pos-sync' && m['port'] != null) {
            final url = 'http://${d.address.address}:${m['port']}';
            found[url] = DiscoveredServer(url, '${m['name'] ?? ''}');
          }
        } catch (_) {
          // Boshqa dastur javobi — e'tiborsiz.
        }
      });
      final dests = targets ?? await _broadcastTargets();
      // UDP yo'qolishi mumkin: ikki marta yuboramiz.
      for (var i = 0; i < 2; i++) {
        for (final a in dests) {
          try {
            s.send(utf8.encode(magic), a, discoveryPort);
          } catch (_) {}
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await Future<void>.delayed(wait);
      await sub.cancel();
    } catch (_) {
      // Tarmoq yo'q — topilmadi.
    } finally {
      sock?.close();
    }
    return found.values.toList();
  }

  /// 255.255.255.255 va har bir tarmoq interfeysining /24 broadcast manzili
  /// (bir nechta adapterli Windows'da umumiy broadcast bittasiga ketadi).
  static Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = [InternetAddress('255.255.255.255')];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          if (a.isLoopback) continue;
          final p = a.rawAddress;
          targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([p[0], p[1], p[2], 255])));
        }
      }
    } catch (_) {}
    return targets;
  }
}
