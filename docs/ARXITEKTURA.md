# POS Terminal — arxitektura va bosqichlar

Bu hujjat tizim qanday qurilganini, 12 bosqichning har birida nima qilinganini,
ma'lumotlar bazasi tuzilmasini va sinxronlash qoidalarini tushuntiradi.

---

## 1. Umumiy ko'rinish

```
┌───────────────────────────┐      ┌───────────────────────────┐
│  Notebook (Windows/macOS/ │      │  Telefon (Android/iOS)    │
│  Linux) — Flutter ilova   │      │  — xuddi shu ilova        │
│  ┌─────────────────────┐  │      │  ┌─────────────────────┐  │
│  │ Lokal SQLite (Drift)│  │      │  │ Lokal SQLite (Drift)│  │
│  └─────────────────────┘  │      │  └─────────────────────┘  │
│  USB skaner ×2, printer ×2│      │  Kamera/BT skaner, BT/LAN │
└─────────────┬─────────────┘      └─────────────┬─────────────┘
              │  push/pull (HTTP, X-API-Key)     │
              └──────────────┐   ┌───────────────┘
                             ▼   ▼
                 ┌──────────────────────────┐
                 │ Sinxronlash serveri      │   (ixtiyoriy)
                 │ FastAPI + PostgreSQL     │
                 └──────────────────────────┘
```

**Asosiy qaror — har bir qurilma mustaqil (offline-first).**
Har bir qurilmada to'liq lokal baza bor. Savdo, ombor, hisobotlar internetsiz va
serversiz ishlaydi. Server faqat o'zgarishlarni almashish uchun. Shuning uchun:

- notebook o'chiq bo'lsa ham telefon savdo qilaveradi;
- internet uzilsa, kassa to'xtamaydi — o'zgarishlar navbatda turadi;
- server (VPS, mini-PC yoki notebookning o'zi) qaytib kelganda hammasi avtomatik birlashadi.

Muqobil variant ("telefon notebookka ulangan holda ishlaydi") rad etildi, chunki unda
notebook o'chishi bilan telefon ham to'xtardi.

## 2. Texnologiyalar

| Qatlam | Tanlov | Sabab |
|---|---|---|
| UI | Flutter 3.47, Material 3 | Bitta kod — 5 platforma |
| Holat (state) | Riverpod 3 (`Notifier`, `StreamProvider`) | Reaktiv: baza o'zgarsa UI o'zi yangilanadi |
| Lokal baza | Drift 2 (SQLite) | Tipga xavfsiz SQL, reaktiv `watch()` so'rovlar, tranzaksiyalar, migratsiya |
| Printer | `esc_pos_utils_plus` (ESC/POS buyruqlar), `print_bluetooth_thermal` (BT), TCP soket (LAN), Windows spooler (FFI), CUPS `lp -o raw` | Barcha ulanish turlari |
| Skaner | Klaviatura-wedge tinglovchi (USB/BT HID), `mobile_scanner` (kamera) | Drayversiz, ikki skaner bir vaqtda |
| Grafiklar | `fl_chart` | Dashboard va mavsumiy grafiklar |
| Bildirishnomalar | `flutter_local_notifications` | Alertlar tizim bildirishnomasi sifatida |
| Server | FastAPI, SQLAlchemy 2, PostgreSQL 16 (yoki SQLite) | Yengil, Docker bilan bitta buyruqda |

Pul summalari **butun so'm** (`int`) da saqlanadi — kasr xatolari bo'lmasligi uchun.
Miqdor `double` (metr, kg kabi kasr birliklar uchun).

## 3. Papkalar tuzilmasi

```
pos-terminal/
├─ app/                        Flutter ilova
│  ├─ lib/
│  │  ├─ core/                 konstantalar, mavsumlar, formatlash, xavfsizlik, tema
│  │  ├─ data/
│  │  │  ├─ database.dart      jadvallar (Drift) + database.g.dart (generatsiya)
│  │  │  └─ repositories/      tovar, ombor, savdo, statistika, foydalanuvchi, alert, sozlama
│  │  ├─ state/                Riverpod providerlar, savat (cart) holati
│  │  ├─ services/             checkout, alertlar, bildirishnoma, printer, skaner, sync, demo
│  │  └─ features/             ekranlar: auth, shell, pos, dashboard, alerts, inventory,
│  │                           history, seasonal, users, settings
│  └─ test/                    unit, widget va sinxronlash testlari
├─ server/                     FastAPI sinxronlash serveri (+ Docker, SQL view'lar, testlar)
├─ docs/                       o'rnatish qo'llanmasi, shu hujjat, skrinshotlar
└─ .github/workflows/build.yml barcha platformalar uchun avtomatik build
```

---

## 4. Bosqichlar (1–12)

### 1-bosqich. Loyiha asosi
Flutter loyiha (5 platforma), Riverpod, Drift, tema (yorug'/qorong'u), o'zbekcha (lotin) UI,
`main.dart` da global xato ushlagichlar (ilova kutilmagan xatoda yopilib qolmaydi).

### 2-bosqich. Ma'lumotlar bazasi
10 ta jadval (5-bo'lim). Har bir sinxronlanadigan jadvalda UUID kalit va sinxron ustunlari.
Boshlang'ich ma'lumotlar: admin foydalanuvchi, 10 ta xo'jalik mollari kategoriyasi
(ularning ID'lari barcha qurilmalarda bir xil — sinxronda dublikat bo'lmasligi uchun).

### 3-bosqich. Rollar va kirish
Admin / Kassir / Omborchi. Parollar PBKDF2-HMAC-SHA256 (20 000 iteratsiya, tasodifiy tuz).
Rolga qarab menyu: kassir dashboard va sozlamalarni ko'rmaydi, omborchi kassani ko'rmaydi.
Muhim amallar — 20% dan katta chegirma tasdig'i va chekni qaytarish — `audit_log` ga yoziladi (kim, qachon, nima).
Oxirgi adminni o'chirib bo'lmaydi.

### 4-bosqich. Kassa ekrani (POS)
- Chap tomon (~63%): qidiruv (nom, shtrix-kod, artikul, kategoriya, brend), savat
  (+/−, miqdorni kiritish, o'chirish), jami, chegirma, to'lov, chop etish.
- O'ng tomon (~37%): "Tez-tez sotiladigan" (7/30 kun) va "Mavsumiy tavsiyalar" — bir bosishda savatga.
- Yuqori panel: bugungi savdo (maqsadga nisbatan progress), cheklar soni, o'rtacha chek, alertlar,
  sinxron holati, mavzu almashtirgich, profil.
- Telefon (tor ekran): savat / tez sotiladigan / mavsumiy — tablarda, pastki navigatsiya.
- Tezkor tugmalar: F2, F4, F8, F9, F12; to'lov oynasida F1–F4, Enter, Esc.

### 5-bosqich. Chegirma va to'lov
- Chegirma foizda (1–20% tez tugmalar) yoki summada. Kassir uchun chegara 20%;
  undan katta bo'lsa admin login/parol bilan joyida tasdiqlaydi (kim tasdiqlagani chekda saqlanadi).
- Chegirma chek qatorlariga mutanosib taqsimlanadi (qaytarishda to'g'ri summa qaytadi).
- To'lov: naqd (qaytim hisoblanadi, tez summa tugmalari), karta, o'tkazma, aralash.
- Checkout **bitta tranzaksiyada**: chek + qatorlar + ombor harakatlari + mavsumiy statistika +
  chek raqami. Yarim yozilgan chek bo'lmaydi.

### 6-bosqich. Chek va printerlar
- Chek dizayni: do'kon ma'lumotlari, chek raqami, kassir, qatorlar, chegirma, to'lov, qaytim,
  pastki matn. 58 mm (32 belgi) va 80 mm (48 belgi).
- 2 printer: har biri tarmoq / Bluetooth / tizim (USB) printeri bo'lishi mumkin; "1-printer",
  "2-printer" yoki "Ikkalasi"; nusxalar soni, qog'oz kesish, pul qutisi.
- Chop etish navbati: printer band yoki o'chiq bo'lsa savdo to'xtamaydi, xato alert sifatida chiqadi.
- O'zbek harflari (oʻ, gʻ, ʼ) va kirill harflari oddiy ASCII ga o'giriladi — har qanday printerda o'qiladi.
- Chekni ko'rish va qayta chop etish (oxirgi chek tugmasi, savdo tarixidan).

### 7-bosqich. Skanerlar
- USB/Bluetooth HID skanerlar: `BarcodeKeyboardListener` tez kiritilgan belgilarni
  (har biri ≤60 ms, ≥4 belgi, Enter bilan tugaydi) skaner deb taniydi — qidiruv fokusda
  bo'lmasa ham ishlaydi. Ikki skaner bir vaqtda ulanishi mumkin.
- Kamera skaneri (Android, iOS, macOS).
- Bazada yo'q kod: kassada — "topilmadi" xabari; kirimda — yangi tovar kartasini ochish taklifi.

### 8-bosqich. Ombor
- Tovar kartasi: 30+ standart atribut (5.3-bo'lim).
- Qoldiq faqat **harakatlar jurnali** orqali o'zgaradi: kirim, sotuv, mijoz qaytardi,
  hisobdan chiqarish, yetkazib beruvchiga qaytarish, inventarizatsiya tuzatish.
  `products.stock_qty` — jurnal yig'indisining keshi, "Qoldiqlarni qayta hisoblash" bilan tiklanadi.
- Kirim (skaner): ketma-ket skanerlash, miqdor va kirim narxi, bitta tugma bilan qabul qilish.
- Filtrlar: kategoriya, kam qolganlar, nofaollar; ombor qiymati (kirim narxida).

### 9-bosqich. Savdo tarixi
Filtrlar: sana oralig'i, kassir, to'lov turi, summa oralig'i, chek raqami.
Chekni ochish, qayta chop etish, qaytarish (faqat admin; tovarlar omborga qaytadi,
mavsumiy statistikadan ayiriladi). Kassir faqat o'z cheklarini ko'radi.

### 10-bosqich. Dashboard va mavsumiy tahlil
- Dashboard: bugun / kecha / hafta / oy — tushum, cheklar, o'rtacha chek, taxminiy foyda,
  chegirmalar, to'lov turlari; kunlik maqsad progressi; 14 kunlik grafik; top tovarlar;
  kassirlar bo'yicha savdo; real-time qoldiq (kam qolganlar).
- Mavsumlar: qish (dek–fev, dekabr keyingi yil qishiga kiradi), bahor (mar–may),
  yoz (iyun–avg), kuz (sen–noy). Joriy mavsum sanadan avtomatik aniqlanadi.
- Har bir mavsum uchun alohida reyting (yillar bo'yicha filtr). `seasonal_stats` jadvali har
  sotuvda oshiriladi, qaytarishda kamaytiriladi; kerak bo'lsa SQL bilan qayta quriladi.
- "Mavsumiy tavsiyalar" paneli: joriy mavsumda o'tgan yillari eng ko'p sotilgan tovarlar,
  yetmasa — mavsum belgisi qo'yilgan tovarlar bilan to'ldiriladi.
- Hamma ko'rsatkichlar Drift `watch()` orqali real vaqtda yangilanadi.

### 11-bosqich. Alertlar
- Kam qoldiq (`stock ≤ min_stock`), tovar tugadi (`stock ≤ 0`) — har sotuv/harakatdan keyin
  va ilova ochilganda tekshiriladi; qoldiq tiklansa alert avtomatik yopiladi.
- Kunlik maqsad bajarilmadi — belgilangan soatdan keyin (standart 18:00), har 5 daqiqada.
- Anomal chek — absolyut chegaradan (standart 5 mln) yoki o'rtacha chekdan N barobar (standart 5)
  katta; 20% dan katta chegirma ham qayd etiladi.
- Ko'rinishi: yuqori paneldagi hisoblagich, Alertlar sahifasi, ekrandagi xabar va tizim
  bildirishnomasi. Takrorlanmaslik uchun `dedupe_key`.

### 12-bosqich. Sinxronlash, testlar, build va hujjatlar
- Sinxronlash serveri va protokol (6-bo'lim), konflikt qoidalari.
- Testlar: 19 ta Flutter testi (savat, chegirma, checkout, mavsum, widget smoke, klaviatura,
  ikki qurilma sinxroni) + 9 ta server testi.
- GitHub Actions: Android APK/AAB, iOS (imzosiz), Windows, macOS, Linux, server Docker image.
- O'rnatish qo'llanmasi: `docs/ORNATISH_QOLLANMASI.md`.

---

## 5. Ma'lumotlar bazasi

### 5.1. Sinxron ustunlari (har bir sinxronlanadigan jadvalda)

| Ustun | Ma'nosi |
|---|---|
| `id` | UUID v4 — qurilmalar orasida to'qnashmaydi |
| `created_at`, `updated_at` | ms (epoch) |
| `version` | har o'zgarishda +1 |
| `device_id` | oxirgi o'zgartirgan qurilma |
| `is_deleted` | yumshoq o'chirish (o'chirish ham sinxronlanadi) |
| `dirty` | 1 — serverga hali yuborilmagan (faqat lokal, serverga yuborilmaydi) |

### 5.2. Jadvallar

| Jadval | Sinxron | Vazifasi |
|---|---|---|
| `users` | ✓ | Foydalanuvchilar, rol, parol xeshi |
| `categories` | ✓ | Kategoriyalar (ierarxiya `parent_id`) |
| `products` | ✓ | Tovarlar (5.3) |
| `sales` | ✓ | Cheklar: summa, chegirma, to'lov turlari, qaytim, holat |
| `sale_items` | ✓ (faqat qo'shiladi) | Chek qatorlari: narx, kirim narxi, chegirma ulushi |
| `stock_movements` | ✓ (faqat qo'shiladi) | Ombor harakatlari jurnali (ishorali miqdor) |
| `audit_log` | ✓ (faqat qo'shiladi) | Muhim amallar jurnali |
| `seasonal_stats` | — | Mavsumiy agregat (har qurilmada sotuvlardan quriladi) |
| `alerts` | — | Ogohlantirishlar (har qurilmada o'zi hosil qiladi) |
| `settings` | — | Kalit-qiymat sozlamalar (qurilmaga xos) |

### 5.3. Tovar atributlari (standart)

| Guruh | Ustunlar |
|---|---|
| Identifikatsiya | `sku` (artikul), `barcode` (EAN-13/EAN-8/UPC/Code128), `barcode2` (qadoq kodi), `name`, `short_name` (chek uchun), `description` |
| Tasnif | `category_id`, `brand`, `manufacturer`, `country`, `supplier` |
| Soliq / fiskal | `mxik_code` (MXIK/IKPU), `package_code` (o'lchov birligi kodi), `vat_percent` (QQS, standart 12%) |
| O'lchov | `unit` (dona, kg, gramm, litr, metr, m², quti, juft, to'plam, rulon, paket), `pack_qty`, `is_weighted` |
| Narx | `purchase_price` (kirim), `sale_price` (sotuv), `wholesale_price` (ulgurji) |
| Ombor | `stock_qty` (kesh), `min_stock` (alert chegarasi), `max_stock`, `location` (javon) |
| Xususiyatlar | `color`, `size`, `material`, `weight_kg`, `volume_l`, `warranty_months` |
| Mavsum | `season_tags` (`winter,autumn` kabi) |
| Boshqa | `is_active`, `image_path`, `notes` |

Shtrix-kodi yo'q tovarlar uchun ilova ichki EAN-13 kod yaratadi (`200…` prefiksi —
do'kon ichki kodlari uchun ajratilgan diapazon).

---

## 6. Sinxronlash protokoli

```
Qurilma                                   Server
  │ 1. PUSH: dirty=1 qatorlar ──────────────▶ │ har bir yozuv uchun qoida tekshiriladi,
  │    (tartib: users → categories →          │ qabul qilinsa seq++ (global tartib)
  │     products → sales → sale_items →       │
  │     stock_movements → audit_log)          │
  │ ◀──────────── accepted / conflicts ────── │
  │    accepted → dirty=0                     │
  │    conflict → serverdagi versiya olinadi  │
  │ 2. PULL: seq > kursor ──────────────────▶ │
  │ ◀──────────── yozuvlar (seq tartibida) ── │
  │    lokal bazaga qo'llanadi, kursor saqlanadi
```

- Interval bo'yicha (standart 30 s), har savdodan 3 s keyin va bulut belgisini bosganda.
- Server `seq` ni bitta qatorli hisoblagichni `SELECT … FOR UPDATE` bilan bloklab beradi —
  tranzaksiyalar commit tartibida raqamlanadi, pull hech qachon yozuvni o'tkazib yubormaydi.
- Har bir yozuv alohida `try/catch` da qo'llanadi: bitta buzilgan yozuv butun sinxronni to'xtatmaydi
  (xato alert sifatida chiqadi).

### Konflikt qoidalari

| Holat | Qoida |
|---|---|
| Bir yozuv ikki qurilmada o'zgartirildi (masalan narx) | **Oxirgi yozuv g'olib** (`updated_at`; teng bo'lsa `device_id` bo'yicha — natija barcha qurilmada bir xil) |
| Chek bir qurilmada qaytarildi, boshqasida tahrirlandi | **`refunded` holati doim g'olib** |
| Chek qatorlari, ombor harakatlari, audit | **Faqat qo'shiladi** — o'zgartirilmaydi, to'qnashmaydi |
| Qoldiq | Hech qachon to'g'ridan-to'g'ri sinxronlanmaydi: har qurilma barcha harakatlar yig'indisidan hisoblaydi. Ikki qurilma bir vaqtda offline sotsa ham qoldiq to'g'ri chiqadi (10 − 3 − 4 = 3) |
| Chek raqamlari | Har qurilmaning o'z prefiksi (`K1-…`, `T1-…`) — to'qnashmaydi |
| Ikki qurilmada bir xil login yaratildi | Lokal xodim loginiga qisqa qo'shimcha qo'shiladi (`kassir_1a2b`), alert chiqadi |
| Boshlang'ich ma'lumotlar (admin, kategoriyalar) | Barcha qurilmalarda bir xil ID — dublikat bo'lmaydi |

Bu ssenariylar `app/test/sync_integration_test.dart` da haqiqiy server (PostgreSQL) bilan tekshirilgan.

---

## 7. Xavfsizlik

- Parollar faqat xesh ko'rinishida (PBKDF2-SHA256, 20 000 iteratsiya, tasodifiy tuz).
- 20% dan katta chegirma va chek qaytarish faqat admin (tasdiq audit jurnaliga yoziladi).
- Server `X-API-Key` bilan himoyalangan (`secrets.compare_digest`). Internetga chiqarilganda HTTPS
  (Caddy/Nginx) tavsiya etiladi.
- Lokal baza shifrlanmagan — qurilmaning o'zini (Windows parol, telefon qulfi) himoyalang.

## 8. Kengaytirish

- Yangi ustun: `database.dart` ga qo'shing → `schemaVersion` ni oshiring → `migration` da
  `addColumn` → `dart run build_runner build`. Server o'zgarmaydi (JSON saqlaydi).
- Fiskal modul (OFD / onlayn-KKM) ulash uchun tayyor maydonlar bor: `mxik_code`, `package_code`,
  `vat_percent`; chek tuzilishi `services/printing/receipt_layout.dart` da.
