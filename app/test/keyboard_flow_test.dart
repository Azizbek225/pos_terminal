import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/app.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/services/notification_service.dart';
import 'package:pos_terminal/state/providers.dart';
import 'package:pos_terminal/data/repositories/product_repository.dart';
import 'package:drift/drift.dart' show Value;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets("Klaviatura: qidiruvda Enter tovar qo'shadi, F4 chegirma, F12 to'lov", (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      await ProductRepository(db, () async => 'd').save(
        const ProductsCompanion(
          name: Value('Elektr isitgich'),
          salePrice: Value(1000),
          barcode: Value('4780000000017'),
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider.overrideWithValue(NotificationService()),
        ],
        child: const PosApp(),
      ),
    );
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'admin');
    await tester.enterText(find.byType(TextField).at(1), 'admin123');
    await tester.runAsync(() async {
      await tester.tap(find.text('Kirish'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, 'isit');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle(tester);
    expect(find.text('Elektr isitgich'), findsWidgets);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle(tester);
    expect(find.textContaining('JAMI: 1 000'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await settle(tester);
    expect(find.text("Qo'llash"), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    final prod = await tester.runAsync(() => ProductRepository(db, () async => 'd').findByBarcode('4780000000017'));
    container.read(cartProvider.notifier).add(prod!);
    await settle(tester);
    expect(find.textContaining('JAMI: 2 000'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await settle(tester);
    expect(find.text("To'lanadigan summa"), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
  });
}
