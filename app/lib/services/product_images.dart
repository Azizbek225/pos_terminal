import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'photo_capture_page.dart';

/// Tovar rasmlari: ilova papkasidagi `product_images/` ga nusxa olinadi,
/// bazada (`products.imagePath`) faqat fayl nomi saqlanadi — shuning uchun
/// papka ko'chsa ham havola buzilmaydi.
class ProductImages {
  ProductImages._();

  static String? _dir;

  /// Ilova ishga tushganda bir marta chaqiriladi (main.dart).
  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'product_images'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir.path;
    } catch (e) {
      debugPrint('Rasm papkasi ochilmadi: $e');
    }
  }

  @visibleForTesting
  static set debugDir(String? dir) => _dir = dir;

  /// Telefon/planshetda tizim kamerasi, Windows'da web-kamera.
  static bool get cameraSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isWindows);

  static bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Fayl nomidan to'liq yo'l. Fayl yo'q bo'lsa (masalan, boshqa qurilmada
  /// qo'shilgan rasm) — null.
  static File? resolve(String name) {
    if (name.isEmpty || _dir == null) return null;
    final f = File(p.isAbsolute(name) ? name : p.join(_dir!, name));
    return f.existsSync() ? f : null;
  }

  /// Fayl nomi uchun to'liq yo'l (fayl hali bo'lmasa ham). Papka yo'q bo'lsa — null.
  static String? pathFor(String name) {
    if (name.isEmpty || _dir == null || p.isAbsolute(name)) return null;
    return p.join(_dir!, name);
  }

  /// Rasm tanlaydi va nusxasini saqlaydi. Qaytaradi: yangi fayl nomi yoki null (bekor qilindi).
  /// [maxSize] — prays-list kabi hujjatlar uchun kattaroq (matn o'qilishi uchun).
  static Future<String?> pick(BuildContext context,
      {required bool camera, double maxSize = 800, String title = 'Tovarni suratga olish'}) async {
    final XFile? picked;
    if (camera && !_isMobile) {
      picked = await capturePhotoWithWebcam(context, title: title);
    } else {
      picked = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: maxSize,
        maxHeight: maxSize,
        imageQuality: 85,
      );
    }
    if (picked == null) return null;
    if (_dir == null) await init();
    if (_dir == null) throw Exception('Rasm papkasi mavjud emas');
    var ext = p.extension(picked.path).toLowerCase();
    if (ext.isEmpty) ext = '.jpg';
    final name = '${const Uuid().v4()}$ext';
    await File(p.join(_dir!, name)).writeAsBytes(await picked.readAsBytes(), flush: true);
    return name;
  }

  /// Endi ishlatilmaydigan rasm faylini o'chiradi.
  static Future<void> delete(String name) async {
    final f = resolve(name);
    if (f == null) return;
    try {
      await f.delete();
    } catch (_) {}
  }
}
