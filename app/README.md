# POS Terminal — Flutter ilova

Loyiha haqida umumiy ma'lumot: [../README.md](../README.md).
O'rnatish: [../docs/ORNATISH_QOLLANMASI.md](../docs/ORNATISH_QOLLANMASI.md).

## Ishlab chiquvchi uchun

```bash
flutter pub get
flutter analyze
flutter test                                   # unit + widget testlar
dart run build_runner build --delete-conflicting-outputs   # database.dart o'zgarsa
```

Sinxronlash testi haqiqiy server bilan:
```bash
cd ../server && POS_API_KEY=testkey uvicorn app.main:app --port 8000 &
cd ../app && SYNC_TEST_URL=http://127.0.0.1:8000 SYNC_TEST_KEY=testkey flutter test test/sync_integration_test.dart
```

## Kod tuzilmasi

| Papka | Vazifasi |
|---|---|
| `lib/core/` | Konstantalar (rollar, to'lov turlari, harakat turlari), mavsumlar, formatlash, parol xeshlash, tema |
| `lib/data/database.dart` | Drift jadvallari; `database.g.dart` — generatsiya qilingan |
| `lib/data/repositories/` | Bazaga murojaat: tovar, ombor, savdo, statistika, foydalanuvchi, alert, sozlamalar |
| `lib/state/` | Riverpod providerlar, savat holati |
| `lib/services/` | Checkout (tranzaksiya), alertlar, bildirishnomalar, printer, skaner, sinxronlash, demo ma'lumot |
| `lib/features/` | Ekranlar |
| `test/` | Testlar |
