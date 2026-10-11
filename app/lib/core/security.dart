import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

/// Parollarni xavfsiz saqlash: PBKDF2-HMAC-SHA256 + tasodifiy salt.
///
/// Parolning o'zi hech qachon bazada saqlanmaydi; faqat hash va salt.
class PasswordHasher {
  PasswordHasher._();

  static const int iterations = 20000;
  static const int keyLength = 32;

  static String newSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return base64Url.encode(bytes);
  }

  static String hash(String password, String salt) {
    final key = _pbkdf2(utf8.encode(password), utf8.encode(salt), iterations, keyLength);
    return base64Url.encode(key);
  }

  static bool verify(String password, String salt, String expectedHash) {
    final actual = hash(password, salt);
    // Doimiy vaqtli taqqoslash (timing-attack'dan himoya).
    if (actual.length != expectedHash.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ expectedHash.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iters, int len) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    var block = 1;
    while (out.length < len) {
      final blockBytes = Uint8List(4)..buffer.asByteData().setUint32(0, block);
      var u = hmac.convert([...salt, ...blockBytes]).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iters; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
      block++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, len));
  }
}

/// UUID va vaqt yordamchilari.
class Ids {
  Ids._();
  static const _uuid = Uuid();

  /// Har bir yozuv uchun global noyob ID (qurilmalar o'rtasida to'qnashmaydi).
  static String newId() => _uuid.v4();

  static int nowMs() => DateTime.now().millisecondsSinceEpoch;
}
