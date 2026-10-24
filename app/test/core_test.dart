import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/season.dart';
import 'package:pos_terminal/core/security.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/services/printing/receipt_layout.dart';
import 'package:pos_terminal/state/cart.dart';

Product _p(String id, int price) => Product(
      id: id, sku: '', barcode: '', barcode2: '', name: 'P$id', shortName: '', description: '',
      categoryId: null, brand: '', manufacturer: '', country: '', supplier: '', mxikCode: '', packageCode: '',
      vatPercent: 12, unit: 'dona', packQty: 1, isWeighted: false, purchasePrice: 0, salePrice: price,
      wholesalePrice: 0, stockQty: 0, minStock: 0, maxStock: 0, location: '', color: '', size: '', material: '',
      weightKg: 0, volumeL: 0, warrantyMonths: 0, seasonTags: '', isActive: true, imagePath: '', notes: '',
      createdAt: 0, updatedAt: 0, version: 1, deviceId: '', isDeleted: false, dirty: false,
    );

void main() {
  group('Mavsum', () {
    test('oylar to\'g\'ri mavsumga tushadi', () {
      expect(Season.of(DateTime(2026, 1, 10)), Season.winter);
      expect(Season.of(DateTime(2026, 12, 1)), Season.winter);
      expect(Season.of(DateTime(2026, 3, 1)), Season.spring);
      expect(Season.of(DateTime(2026, 7, 15)), Season.summer);
      expect(Season.of(DateTime(2026, 10, 4)), Season.autumn);
    });
    test('dekabr keyingi yil qishiga tegishli', () {
      expect(Season.seasonYear(DateTime(2025, 12, 20)), 2026);
      expect(Season.seasonYear(DateTime(2026, 1, 20)), 2026);
    });
    test('teglar kodlanadi va o\'qiladi', () {
      final tags = {Season.autumn, Season.winter};
      expect(encodeSeasonTags(tags), 'winter,autumn');
      expect(parseSeasonTags('winter, autumn,xyz'), tags);
    });
  });

  group('Parol', () {
    test('hash tekshiruvi', () {
      final salt = PasswordHasher.newSalt();
      final h = PasswordHasher.hash('sir123', salt);
      expect(PasswordHasher.verify('sir123', salt, h), isTrue);
      expect(PasswordHasher.verify('sir124', salt, h), isFalse);
    });

    test('server (web panel) bilan bir xil hash', () {
      // server/tests/test_web.py dagi qiymat: Python hashlib.pbkdf2_hmac.
      expect(PasswordHasher.hash('admin123', 'c2FsdC1zYWx0'), 'WsSn7hSEnQkDNa6kbkYPPMlODSkg_W8tojHw5dLlxiI=');
    });
  });

  group('Savat', () {
    test('foiz chegirma va taqsimot yig\'indisi aniq', () {
      final cart = CartState(lines: [
        CartLine(product: _p('a', 10001), qty: 3),
        CartLine(product: _p('b', 7777), qty: 1),
        CartLine(product: _p('c', 333), qty: 7),
      ], discountType: DiscountType.percent, discountValue: 15);
      expect(cart.subtotal, 30003 + 7777 + 2331);
      expect(cart.discountAmount, (cart.subtotal * 0.15).round());
      final parts = cart.allocateDiscount();
      expect(parts.reduce((a, b) => a + b), cart.discountAmount);
      expect(cart.total, cart.subtotal - cart.discountAmount);
    });
    test('summa chegirmasi chekdan oshmaydi', () {
      final cart = CartState(
          lines: [CartLine(product: _p('a', 1000), qty: 1)], discountType: DiscountType.amount, discountValue: 5000);
      expect(cart.discountAmount, 1000);
      expect(cart.total, 0);
    });
  });

  group('Chek matni', () {
    test('o\'zbekcha apostroflar va kirill printer uchun tozalanadi', () {
      expect(ReceiptLayout.sanitize('O‘zbekiston gʻisht'), "O'zbekiston g'isht");
      expect(ReceiptLayout.sanitize('Чой'), 'Choy');
    });
  });
}
