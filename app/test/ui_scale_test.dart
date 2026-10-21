import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/ui_scale.dart';

void main() {
  testWidgets('80% masshtabda sahifaga kattaroq maydon beriladi', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Size? inner;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => UiScale(scale: 0.8, child: child!),
      home: Builder(builder: (context) {
        inner = MediaQuery.sizeOf(context);
        return const Scaffold(body: Center(child: Text('Savdo')));
      }),
    ));
    expect(inner, const Size(1000, 750));
    // Ekranda (o'zgartirishdan keyin) yozuv 20% kichik.
    final r = tester.getRect(find.text('Savdo'));
    expect(r.height, closeTo(tester.getSize(find.text('Savdo')).height * 0.8, 0.01));
  });
}
