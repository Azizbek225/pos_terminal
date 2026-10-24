@Tags(['server'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/constants.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/services/sync/sync_service.dart';

import 'test_helpers.dart';

/// Web kassada (PosServer brauzerda) qilingan savdo, kirim va qaytarish
/// ilovaga oddiy sinxronlash bilan to'g'ri keladi.
///   SYNC_TEST_URL=http://127.0.0.1:8000 SYNC_TEST_KEY=... flutter test test/web_kassa_sync_test.dart
void main() {
  final url = Platform.environment['SYNC_TEST_URL'];
  final key = Platform.environment['SYNC_TEST_KEY'] ?? '';

  test('web kassa yozuvlari ilovaga keladi', () async {
    final http = HttpClient();
    String? cookie;
    Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async {
      final req = await http.postUrl(Uri.parse('$url$path'));
      req.headers.contentType = ContentType.json;
      if (cookie != null) req.headers.set('cookie', cookie!);
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      expect(res.statusCode, 200, reason: '$path: $text');
      final set = res.headers[HttpHeaders.setCookieHeader];
      if (set != null && set.isNotEmpty) cookie = set.first.split(';').first;
      return jsonDecode(text) as Map<String, dynamic>;
    }

    // Login "admin" + API kalit (xodimlar hali sinxronlanmagan server).
    await post('/api/kassa/login', {'username': 'admin', 'password': key});
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final p = await post('/api/kassa/product', {
      'branch_id': kDefaultBranchId, 'name': 'Web tovar $stamp', 'barcode': 'w$stamp',
      'sale_price': 12000, 'purchase_price': 8000, 'unit': 'kg', 'is_weighted': true,
    });
    await post('/api/kassa/stock_in', {
      'branch_id': kDefaultBranchId, 'lines': [{'product_id': p['id'], 'qty': 10}],
    });
    final sale = await post('/api/kassa/sale', {
      'branch_id': kDefaultBranchId, 'lines': [{'product_id': p['id'], 'qty': 2.5}],
      'discount_type': 'amount', 'discount_value': 1000, 'paid_cash': 30000,
    });
    final refunded = await post('/api/kassa/sale', {
      'branch_id': kDefaultBranchId, 'lines': [{'product_id': p['id'], 'qty': 1}], 'paid_card': 12000,
    });
    await post('/api/kassa/refund', {'sale_id': refunded['id'], 'reason': 'test'});
    http.close();

    final dir = Directory.systemTemp.createTempSync('pos_web_');
    final env = TestEnv(NativeDatabase(File('${dir.path}/pos.sqlite')));
    await env.settings.setAll({
      SettingKeys.syncEnabled: '1',
      SettingKeys.syncUrl: url!,
      SettingKeys.syncApiKey: key,
      SettingKeys.deviceCode: 'T9',
    });
    final sync = SyncService(db: env.db, settings: env.settings, stock: env.stock, stats: env.stats, alerts: env.alerts);
    await sync.syncNow();
    expect(sync.status.value.state, SyncState.ok, reason: sync.status.value.message);

    final product = (await env.products.byId(p['id'] as String))!;
    expect(product.isWeighted, isTrue);
    expect(product.stockQty, 10 - 2.5); // qaytarilgan chek omborga qaytdi
    final s = (await env.sales.getWithItems(sale['id'] as String))!;
    expect(s.sale.receiptNo, sale['receipt_no']);
    expect(s.sale.total, 29000);
    expect(s.sale.changeAmount, 1000);
    expect(s.items.single.qty, 2.5);
    expect(s.items.single.lineTotal, 29000);
    final r = (await env.sales.getWithItems(refunded['id'] as String))!;
    expect(r.sale.status, SaleStatus.refunded.code);
  }, skip: url == null ? 'SYNC_TEST_URL berilmagan' : null);
}
