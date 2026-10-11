import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/app.dart';
import 'package:pos_terminal/data/database.dart';
import 'package:pos_terminal/data/repositories/settings_repository.dart';
import 'package:pos_terminal/data/repositories/stats_repository.dart';
import 'package:pos_terminal/data/repositories/stock_repository.dart';
import 'package:pos_terminal/data/repositories/user_repository.dart';
import 'package:pos_terminal/services/demo_data.dart';
import 'package:pos_terminal/services/notification_service.dart';
import 'package:pos_terminal/state/providers.dart';

/// Barcha bo'limlarni keng (notebook) va tor (telefon) ekranda ochib,
/// layout xatolari yo'qligini tekshiradi.
void main() {
  Future<AppDatabase> seeded(WidgetTester tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await tester.runAsync(() async {
      final settings = SettingsRepository(db);
      Future<String> dev() => settings.deviceId();
      final admin = await UserRepository(db, dev).login('admin', 'admin123');
      await DemoDataService(db, settings, StockRepository(db, dev), StatsRepository(db)).load(admin);
    });
    return db;
  }

  Future<void> run(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = await seeded(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(NotificationService()),
      ],
      child: const PosApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Kirish'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'admin');
    await tester.enterText(find.byType(TextField).at(1), 'admin123');
    await tester.runAsync(() async {
      await tester.tap(find.text('Kirish'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('JAMI'), findsWidgets);
    expect(find.textContaining('sotiladigan'), findsWidgets);

    // Tavsiya kartasini bosib savatga qo'shish.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    final wide = size.width >= 900;
    final labels = ['Dashboard', 'Ombor', 'Tarix', 'Mavsumiy', 'Alertlar', 'Xodimlar', 'Sozlamalar', 'Savdo'];
    for (final l in labels) {
      if (wide) {
        await tester.tap(find.text(l).last);
      } else {
        final direct = find.descendant(of: find.byType(NavigationBar), matching: find.text(l));
        if (direct.evaluate().isNotEmpty) {
          await tester.tap(direct.first);
        } else {
          await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.byIcon(Icons.more_horiz)));
          await tester.pumpAndSettle();
          await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text(l)));
        }
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Sahifa: $l');
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
    await tester.runAsync(db.close);
  }

  testWidgets('Notebook ekrani (1440x900)', (t) => run(t, const Size(1440, 900)));

  testWidgets("To'liq savdo jarayoni (chegirma, to'lov) va tovar kartasi", (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = await seeded(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(NotificationService()),
      ],
      child: const PosApp(),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'admin');
    await tester.enterText(find.byType(TextField).at(1), 'admin123');
    await tester.runAsync(() async {
      await tester.tap(find.text('Kirish'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    // Mavsumiy/tez sotiladigan kartadan birinchi tovarni savatga qo'shish.
    final tile = find.descendant(of: find.byType(GridView).first, matching: find.byType(InkWell)).first;
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining("Savat bo'sh"), findsNothing);

    // Chegirma 10%.
    await tester.tap(find.text('Chegirma (F4)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10%'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Qo'llash"));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chegirma: -'), findsOneWidget);

    // To'lov oynasi -> tasdiqlash.
    await tester.tap(find.text("To'lov (F12)"));
    await tester.pumpAndSettle();
    expect(find.text("To'lanadigan summa"), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Tasdiqlash (Enter)'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    final sales = await tester.runAsync(() => db.select(db.sales).get());
    final today = sales!.where((s) => s.discountAmount > 0).toList();
    expect(today, hasLength(1));
    expect(find.textContaining("Savat bo'sh"), findsOneWidget);

    // Ombor -> Yangi tovar.
    await tester.tap(find.text('Ombor').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    // FAB ustida xabarnoma (SnackBar) turgan bo'lishi mumkin — tugmani to'g'ridan-to'g'ri chaqiramiz.
    tester.widget<FloatingActionButton>(find.byType(FloatingActionButton).first).onPressed!();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Tovar kartasidagi barcha atribut maydonlari chizildi (saqlash mantiqi
    // repository testlarida tekshiriladi).
    expect(find.widgetWithText(TextFormField, "To'liq nomi *"), findsOneWidget);
    expect(find.text('Asosiy ma\'lumotlar'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
    await tester.runAsync(db.close);
  });
  testWidgets('Telefon ekrani (400x860)', (t) => run(t, const Size(400, 860)));
}
