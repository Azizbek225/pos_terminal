import 'package:flutter/material.dart';

/// Butun ilovani kichraytirish (masalan 80% yoki 70%): sahifa kattaroq
/// "virtual" ekranga chiziladi va ekranga sig'diriladi — yozuv, tugma va
/// bo'shliqlar birga kichrayadi, ekranga ko'proq narsa sig'adi.
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.scale, required this.child});
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (scale >= 0.999) return child;
    final mq = MediaQuery.of(context);
    final size = mq.size / scale;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: size,
        child: MediaQuery(
          data: mq.copyWith(
            size: size,
            padding: mq.padding / scale,
            viewPadding: mq.viewPadding / scale,
            viewInsets: mq.viewInsets / scale,
            systemGestureInsets: mq.systemGestureInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}
