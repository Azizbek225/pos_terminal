import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/features/suppliers/signature_pad.dart';

void main() {
  testWidgets('imzo PNG ga aylanadi', (tester) async {
    final bytes = await tester.runAsync(() => renderSignaturePng([
          [const Offset(10, 10), const Offset(60, 40), const Offset(120, 20)],
          [const Offset(30, 50)],
        ], const Size(300, 200)));
    expect(bytes, isNotNull);
    expect(bytes!.sublist(1, 4), 'PNG'.codeUnits);
  });

  testWidgets("imzo sahifasi: chizmasdan tasdiqlab bo'lmaydi, chizgach bo'ladi", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => TextButton(onPressed: () => openSignaturePad(c, subtitle: 'Qabul qilindi'), child: const Text('och')),
      ),
    ));
    await tester.tap(find.text('och'));
    await tester.pumpAndSettle();
    FilledButton btn() => tester.widget<FilledButton>(find.ancestor(of: find.text('Imzoni tasdiqlash'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(btn().onPressed, isNull);
    final center = tester.getCenter(find.text("Shu yerga imzo qo'ying"));
    await tester.dragFrom(center, const Offset(120, 30));
    await tester.pump();
    expect(btn().onPressed, isNotNull);
  });
}
