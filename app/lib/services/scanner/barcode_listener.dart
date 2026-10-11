import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// USB va Bluetooth (HID rejimidagi) shtrix-kod skanerlarini qo'llab-quvvatlash.
///
/// Bunday skanerlar operatsion tizim uchun "klaviatura" hisoblanadi: kodni
/// juda tez (har belgi orasida < 50 ms) yozib, oxirida Enter bosadi.
/// Ushbu vidjet global klaviatura oqimini tinglaydi va shunday tez kiritilgan
/// ketma-ketlikni shtrix-kod sifatida ajratib oladi. Shuning uchun:
///  * Bir vaqtda 2 ta (yoki undan ko'p) skaner ulanishi mumkin — ikkalasi
///    ham klaviatura sifatida ishlaydi, maxsus sozlash shart emas.
///  * Kursor qidiruv maydonida bo'lmasa ham skanerlash ishlaydi.
///
/// Agar foydalanuvchi matn maydonida yozayotgan bo'lsa, vidjet aralashmaydi —
/// u holda maydonning `onSubmitted` hodisasi kodni qayta ishlaydi.
class BarcodeKeyboardListener extends StatefulWidget {
  const BarcodeKeyboardListener({
    super.key,
    required this.onBarcode,
    required this.child,
    this.enabled = true,
    this.maxKeyInterval = const Duration(milliseconds: 60),
    this.minLength = 4,
  });

  final ValueChanged<String> onBarcode;
  final Widget child;
  final bool enabled;
  final Duration maxKeyInterval;
  final int minLength;

  @override
  State<BarcodeKeyboardListener> createState() => _BarcodeKeyboardListenerState();
}

class _BarcodeKeyboardListenerState extends State<BarcodeKeyboardListener> {
  final _buffer = StringBuffer();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _textFieldFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent event) {
    if (!widget.enabled || !mounted) return false;
    if (event is! KeyDownEvent) return false;
    if (_textFieldFocused()) {
      _reset();
      return false;
    }
    final now = DateTime.now();
    final gap = now.difference(_last);
    _last = now;

    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString();
      // Enter ham tez kelishi kerak — aks holda bu qo'lda yozilgan matn.
      final fast = gap <= widget.maxKeyInterval * 3;
      _reset();
      if (code.length >= widget.minLength && fast) {
        widget.onBarcode(code);
        return true;
      }
      return false;
    }

    final ch = event.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32) return false;
    if (_buffer.isNotEmpty && gap > widget.maxKeyInterval) {
      // Odam qo'lda yozyapti — yangi ketma-ketlik boshlaymiz.
      _reset();
    }
    _buffer.write(ch);
    return false;
  }

  void _reset() => _buffer.clear();

  @override
  Widget build(BuildContext context) => widget.child;
}
