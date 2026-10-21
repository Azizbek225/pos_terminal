# POS Terminal — o'rnatish qo'llanmasi

Versiya: **1.0.0**

Bu qo'llanma tizimni noldan ishga tushirishni bosqichma-bosqich tushuntiradi:
ilovani yig'ish (build), har bir platformaga o'rnatish, sinxronlash serveri,
printer va skanerlarni ulash hamda birinchi sozlash.

---

## 0. Qisqacha: qaysi variant sizga kerak?

| Holat | Nima qilish kerak |
|---|---|
| Bitta notebook yoki bitta telefon | Faqat ilovani o'rnating. Server **kerak emas**. |
| Notebook + telefon, ma'lumotlar umumiy bo'lsin | Ilovani ikkalasiga o'rnating va **sinxronlash serverini** ishga tushiring (6-bo'lim). |
| Notebook o'chganda ham telefon ishlashi kerak | Bu odatiy holat: har bir qurilma o'z bazasi bilan **mustaqil** ishlaydi. Server faqat ma'lumot almashish uchun kerak. Server o'chiq bo'lsa ham savdo to'xtamaydi. |

> **Muhim qaror.** Har bir qurilma (notebook, telefon) o'zining lokal SQLite bazasiga ega va
> internetsiz to'liq ishlaydi. Server o'chiq bo'lsa, o'zgarishlar qurilmada navbatda turadi va
> server qaytib kelganda avtomatik yuboriladi. Shuning uchun telefon notebookka bog'liq emas.
>
> Eng qulay variant — serverni **arzon VPS** (internetdagi server) yoki do'kondagi doim yoqiq
> mini-kompyuterga o'rnatish. Serverni notebookka o'rnatish ham mumkin: notebook o'chganda
> telefon baribir sotadi, faqat sinxronlash notebook yoqilguncha kutib turadi.

---

## 1. Tayyor fayllarni olish

Ilova Flutter'da yozilgan. Bitta kod bazasidan barcha platformalar uchun build qilinadi.

### 1.1. Eng oson yo'l: GitHub Actions (kompyuterga hech narsa o'rnatmasdan)

1. GitHub'da yangi **private** repozitoriy yarating (masalan `pos-terminal`).
2. Arxivdagi `pos-terminal` papkasi ichidagi hamma narsani repozitoriyga yuklang:
   ```bash
   cd pos-terminal
   git init && git add . && git commit -m "POS Terminal 1.0.0"
   git branch -M main
   git remote add origin https://github.com/<login>/pos-terminal.git
   git push -u origin main
   ```
3. GitHub'da **Actions** bo'limiga o'ting. `build` jarayoni avtomatik boshlanadi:
   testlar → Android, iOS, Windows, macOS, Linux build.
4. Tugagach, jarayon sahifasining pastidagi **Artifacts** bo'limidan fayllarni yuklab oling:
   - `android` → `pos-terminal-android.apk` (telefon/planshet uchun); `.aab` (Play Market uchun) faqat teg qo'yilganda;
   - `windows` → `pos-terminal-windows-x64.zip`;
   - `macos` → `pos-terminal-macos.zip`;
   - `linux` → `pos-terminal-linux-x64.tar.gz`;
   - `ios` → `pos-terminal-ios-unsigned.ipa` (imzosiz, 5-bo'limga qarang).
5. Rasmiy reliz uchun teg qo'ying, shunda fayllar **Releases** sahifasiga chiqadi:
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```

### 1.2. O'z kompyuteringizda build qilish

1. Flutter SDK o'rnating (3.47 yoki yangiroq): https://docs.flutter.dev/get-started/install
2. Tekshiring: `flutter doctor`.
3. Loyiha papkasida:
   ```bash
   cd pos-terminal/app
   flutter pub get
   flutter test            # ixtiyoriy: avtomatik testlar
   ```
4. Kerakli platforma uchun:

| Platforma | Buyruq | Qayerda bajariladi | Natija |
|---|---|---|---|
| Android | `flutter build apk --release` | Windows / macOS / Linux + Android Studio | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows | `flutter build windows --release` | Windows + Visual Studio 2022 ("Desktop development with C++") | `build/windows/x64/runner/Release/` |
| macOS | `flutter build macos --release` | macOS + Xcode | `build/macos/Build/Products/Release/POS Terminal.app` |
| Linux | `flutter build linux --release` | Linux (`clang cmake ninja-build pkg-config libgtk-3-dev`) | `build/linux/x64/release/bundle/` |
| iOS | `flutter build ios --release` | macOS + Xcode + Apple ID | Xcode orqali iPhone'ga o'rnatiladi |

> Ma'lumotlar bazasi kodi (`lib/data/database.g.dart`) tayyor holda keladi.
> Jadval tuzilmasini o'zgartirsangiz, qayta yarating:
> `dart run build_runner build --delete-conflicting-outputs`.

---

## 2. Windows (notebook / kassa kompyuteri)

1. `pos-terminal-windows-x64.zip` faylini oching, masalan `C:\POS Terminal\` papkasiga.
2. `pos_terminal.exe` ni ishga tushiring. Qulaylik uchun ish stoliga yorliq qiling
   (o'ng tugma → *Ярлык / Create shortcut*).
3. Agar "Windows protected your PC" chiqsa: **More info → Run anyway**.
4. Agar ilova ochilmasa, Microsoft Visual C++ Redistributable (x64) o'rnating:
   https://aka.ms/vs/17/release/vc_redist.x64.exe
5. Ma'lumotlar bazasi bu yerda saqlanadi:
   `%APPDATA%\uz.posterminal\pos_terminal\pos_terminal.sqlite`
   (aniq yo'l ilovaning o'zida ham ko'rsatiladi: **Sozlamalar → Ma'lumotlar → Baza fayli**).

**Zaxira nusxa:** ilovani yopib, `pos_terminal.sqlite` faylini fleshka yoki bulutga nusxalang.

## 3. macOS

1. `pos-terminal-macos.zip` ni oching va `POS Terminal.app` ni **Applications** papkasiga torting.
2. Birinchi marta: ilova ustida **o'ng tugma → Open → Open** (Apple'da ro'yxatdan o'tmagan
   dastur bo'lgani uchun). Kerak bo'lsa: *System Settings → Privacy & Security → Open Anyway*.
3. Kamera (skaner uchun) va Bluetooth ruxsatlarini so'raganda **Allow** bosing.
4. Baza: `~/Library/Application Support/uz.posterminal.posTerminal/pos_terminal.sqlite`.

## 4. Linux (Ubuntu / Debian / Mint)

```bash
sudo apt install libgtk-3-0 libsqlite3-0     # odatda allaqachon o'rnatilgan
mkdir -p ~/pos-terminal && tar -xzf pos-terminal-linux-x64.tar.gz -C ~/pos-terminal
~/pos-terminal/bundle/pos_terminal
```

Menyuda yorliq bo'lishi uchun `~/.local/share/applications/pos-terminal.desktop` fayli:
```ini
[Desktop Entry]
Name=POS Terminal
Exec=/home/FOYDALANUVCHI/pos-terminal/bundle/pos_terminal
Type=Application
Categories=Office;
```
Baza: `~/.local/share/uz.posterminal.pos_terminal/pos_terminal.sqlite`.

USB printer uchun foydalanuvchini `lp` guruhiga qo'shing: `sudo usermod -aG lp $USER` (keyin qayta kiring).

## 5. Android va iOS (telefon / planshet)

### Android
1. `pos-terminal-android.apk` faylini telefonga o'tkazing (Telegram, USB, Google Drive).
2. Faylni oching. "Noma'lum manbalardan o'rnatish"ga ruxsat so'rasa — ruxsat bering.
3. Birinchi ochilishda ruxsatlar: **Kamera** (shtrix-kod skaneri), **Yaqin atrofdagi qurilmalar /
   Bluetooth** (printer), **Bildirishnomalar** (alertlar) — hammasiga ruxsat bering.
4. Talab: Android 7.0 (API 24) yoki yangiroq.

> Play Market'ga joylash uchun `.aab` fayl va o'z imzo kalitingiz kerak.
> Kalitni yaratish: `keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias pos`,
> so'ng `app/android/key.properties` faylini yarating
> (`storeFile=release.jks`, `storePassword=...`, `keyAlias=pos`, `keyPassword=...`) va
> `release.jks` ni `app/android/app/` ga qo'ying. GitHub Actions uchun 1-bo'limdagi Secrets'ga qarang.

### iOS (iPhone / iPad)
Apple qoidalariga ko'ra iOS ilovani imzosiz o'rnatib bo'lmaydi. Variantlar:
1. **Mac + Xcode (bepul Apple ID):** `app/ios/Runner.xcworkspace` ni Xcode'da oching →
   *Signing & Capabilities* → Team: o'z Apple ID'ingiz → iPhone'ni ulang → **Run**.
   Bepul Apple ID bilan ilova 7 kun ishlaydi, keyin qayta Run qilish kerak.
2. **Apple Developer Program (yiliga $99):** TestFlight yoki Ad Hoc orqali doimiy o'rnatish.
3. **Sideloadly / AltStore:** `pos-terminal-ios-unsigned.ipa` faylini o'z Apple ID bilan imzolab o'rnatish.

iOS'da Bluetooth printer sifatida **BLE** (Bluetooth Low Energy) qo'llaydigan printer kerak;
klassik Bluetooth printerlar iOS'da ishlamaydi. Eng ishonchli variant — **Wi-Fi/LAN printer**.

---

## 6. Sinxronlash serveri (bir nechta qurilma uchun)

Server — kichik FastAPI dastur + PostgreSQL. U faqat qurilmalar orasida o'zgarishlarni almashadi.

### 6.0. Eng oson yo'l: Windows kompyuterda PosServer.exe

Docker ham, Python ham kerak emas.

1. GitHub → **Actions** → oxirgi yashil build → **Artifacts** bo'limidan `server-windows` ni yuklab oling,
   ichidagi `PosServer.exe` ni masalan `C:\PosServer\` papkaga qo'ying.
2. `PosServer.exe` ni ishga tushiring. Windows "Ruxsat berish" (Allow access) so'rasa — **ruxsat bering**.
3. Oynada **Server manzili** (masalan `http://192.168.1.10:8000`) va **API kalit** chiqadi.
4. Kompyuterda ham, telefonda ham: **Sozlamalar → Sinxronlash** ga shu manzil va kalitni yozing,
   **Ulanishni tekshirish** → **Sinxronlashni yoqish** → **Saqlash** (batafsil 6.4).
5. Oynani yopmang. Baza (`pos.db`), kalit (`api_kalit.txt`) va suratlar (`images`) exe yonida saqlanadi.
   Ehtiyot nusxa uchun shu uchtasini vaqti-vaqti bilan fleshkaga ko'chirib turing.
6. **Avtomatik ishga tushish:** PosServer birinchi marta ochilganda o'zini Windows'ga qo'shadi.
   Keyin kompyuter yonib, Windows'ga kirilganda server o'zi kichraytirilgan oynada ishga tushadi.
   O'chirish kerak bo'lsa: `PosServer.exe --autostart-off`. Exe'ni boshqa papkaga ko'chirsangiz,
   yangi joydan bir marta ishga tushiring.
7. **IP o'zgarsa:** router kompyuterga yangi IP bersa ham hech narsa qilish shart emas — telefon
   serverni tarmoqdan o'zi qayta topadi (faqat avval shu server bilan bir marta sinxronlangan bo'lsa).
   Birinchi sozlashda **Server manzili** maydonidagi 📶 (Serverni topish) tugmasini bossangiz,
   manzil o'zi yoziladi. API kalit o'zgarmaydi (`api_kalit.txt` o'chirilmasa).
   Tailscale ishlatsangiz, Tailscale IP (100.x.x.x) umuman o'zgarmaydi; dastur Wi-Fi va Tailscale
   manzillarini eslab qoladi va qaysi biri ishlasa, o'shanga ulanadi.

Telefon va kompyuter **bitta Wi-Fi**'da bo'lishi kerak.

### 6.1. Docker bilan

Docker o'rnating: Windows/macOS uchun **Docker Desktop**, Linux uchun `curl -fsSL https://get.docker.com | sh`.

```bash
cd pos-terminal/server
cp .env.example .env
# .env faylini oching va POS_API_KEY hamda POSTGRES_PASSWORD ni o'zgartiring.
# Kalit yaratish: openssl rand -hex 24
docker compose up -d
```
Tekshirish: brauzerda `http://localhost:8000/api/health` → `{"status":"ok", ...}`.

Server avtomatik qayta ishga tushadi (`restart: unless-stopped`), kompyuter qayta yoqilganda ham.

### 6.2. Docker'siz (Python 3.11+)

```bash
cd pos-terminal/server
python -m venv .venv
# Windows: .venv\Scripts\activate     Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # POS_API_KEY ni o'zgartiring
uvicorn app.main:app --host 0.0.0.0 --port 8000
```
`.env` da `POS_DATABASE_URL=sqlite:///./pos.db` bo'lsa, PostgreSQL'siz ham ishlaydi
(kichik do'kon uchun yetarli). PostgreSQL uchun:
`POS_DATABASE_URL=postgresql+psycopg://pos:PAROL@localhost:5432/pos`.

### 6.3. Server qayerda tursin?

| Variant | Afzallik | Kamchilik |
|---|---|---|
| **VPS** (oyiga ~$4–6) | Doim yoqiq, telefon istalgan joydan (mobil internet) sinxronlanadi | Oylik to'lov; HTTPS sozlash tavsiya etiladi |
| Do'kondagi mini-PC / doim yoqiq kompyuter | Bepul, tez (lokal tarmoq) | Faqat do'kon Wi-Fi'sida sinxronlanadi |
| Kassa notebooki | Qo'shimcha qurilma kerak emas | Notebook o'chiq bo'lsa sinxronlash kutadi (savdo to'xtamaydi) |

**Lokal tarmoqda (Wi-Fi) ishlatish:**
1. Server kompyuterining IP manzilini toping: Windows `ipconfig`, Linux/macOS `ip a` yoki `ifconfig`
   (masalan `192.168.1.10`).
2. Windows Firewall'da 8000-portga ruxsat bering:
   `netsh advfirewall firewall add rule name="POS Sync" dir=in action=allow protocol=TCP localport=8000`
   (Administrator sifatida ochilgan buyruq oynasida).
3. Router sozlamalarida server kompyuteriga **doimiy IP** (DHCP reservation) bering.

**VPS'da HTTPS (tavsiya):** Caddy bilan eng oson:
```bash
sudo apt install caddy
echo "pos.mening-domenim.uz { reverse_proxy 127.0.0.1:8000 }" | sudo tee /etc/caddy/Caddyfile
sudo systemctl reload caddy
```
Ilovada server manzili: `https://pos.mening-domenim.uz`.

### 6.4. Ilovani serverga ulash (har bir qurilmada)

1. **Sozlamalar → Do'kon va chek → Kassa (qurilma) kodi**: har bir qurilmaga **har xil** kod bering,
   masalan notebook `K1`, telefon `T1`, ikkinchi kassa `K2`. Bu chek raqamlari to'qnashmasligi uchun
   kerak (`K1-000001`, `T1-000001`). Standart qiymat `K1`.
2. **Sozlamalar → Sinxronlash**:
   - **Server manzili**: `http://192.168.1.10:8000` (yoki `https://...`);
   - **API kalit**: `.env` dagi `POS_API_KEY`;
   - **Interval**: masalan 30 soniya;
   - **Ulanishni tekshirish** → "Ulandi: server ishlayapti ..., API kalit to'g'ri" chiqishi kerak;
   - **Sinxronlashni yoqish** → **Saqlash**.
3. Yangi qurilma birinchi marta ulanganda **Serverdan to'liq yuklash** tugmasini bosing.

Yuqori paneldagi bulut belgisi holatni ko'rsatadi: yashil — sinxronlangan, ko'k — sinxronlanmoqda,
to'q sariq — server bilan aloqa yo'q (savdo davom etadi), qizil — xato (masalan, kalit noto'g'ri).
Belgidagi raqam — hali yuborilmagan o'zgarishlar soni. Belgini bosish darhol sinxronlaydi.

> **Maslahat:** tovarlar bazasini bitta qurilmada (masalan notebookda) to'ldiring,
> sinxronlang, keyin qolgan qurilmalarni ulang.

### 6.5. Server hisobotlari

- `GET /api/reports/daily?date_from=2026-10-01&date_to=2026-10-31` (sarlavha `X-API-Key`) —
  barcha qurilmalar bo'yicha kunlik savdo.
- PostgreSQL'da tayyor VIEW'lar (Excel, Power BI, Metabase uchun):
  ```bash
  docker compose exec -T db psql -U pos -d pos < sql/views.sql
  ```
  So'ng `v_sales`, `v_sale_items`, `v_products`, `v_stock`, `v_daily_sales` jadvallaridan o'qing.

### 6.6. Telefondan internet orqali real vaqtda kuzatish (Monitoring)

Do'kondan tashqarida (uyda, yo'lda, mobil internetda) savdoni kuzatish uchun telefon PosServer.exe
turgan kompyuterga internet orqali ulanishi kerak. Eng oson va xavfsiz yo'l — **Tailscale** (bepul):

1. Do'kondagi kompyuterga (PosServer.exe turgan) va telefoningizga **Tailscale** ilovasini o'rnating
   (tailscale.com, Google Play / App Store) va ikkalasida **bitta akkaunt** bilan kiring.
2. Kompyuterdagi Tailscale belgisidan uning IP manzilini oling (`100.x.x.x`).
3. Telefonda POS ilovasi → **Sozlamalar → Sinxronlash** → server manzili `http://100.x.x.x:8000`,
   API kalit — `api_kalit.txt` dagi kalit → **Ulanishni tekshirish** → **Saqlash**.
   (Do'kon Wi-Fi manzili ham eslab qolinadi — dastur qaysi biri ishlasa, o'shandan foydalanadi.)
4. Ilovada **Monitoring** bo'limini oching: u ochiq turganda har **5 soniyada** yangilanadi —
   har bir filialning bugungi savdosi, cheklar soni, foyda, kam qoldiqli tovarlar, oxirgi cheklar
   (qaysi kassir, qancha, qaysi to'lov) va bugungi o'zgarishlar ko'rinadi.

Kassalar har bir savdodan 3 soniya keyin serverga yuboradi, shuning uchun telefonda savdo deyarli
darhol paydo bo'ladi. Telefon internetsiz qolsa — oxirgi olingan ma'lumot ko'rinib turadi.

### 6.7. Server zaxira nusxasi

```bash
docker compose exec -T db pg_dump -U pos pos > zaxira_$(date +%F).sql     # nusxa olish
docker compose exec -T db psql -U pos -d pos < zaxira_2026-10-04.sql      # tiklash
```

---

## 7. Termoprinterlar (ESC/POS, 2 tagacha)

Ilova **2 ta printerni** qo'llaydi: **Sozlamalar → Printerlar** bo'limida "1-printer" va "2-printer"
kartochkalari. "Chek qayerga chiqsin" — `1-printer`, `2-printer` yoki `Ikkalasi`
(masalan, biri mijozga, biri omborga). Har bir printer uchun: qog'oz kengligi **58 mm / 80 mm**,
nusxalar soni, qog'ozni kesish, pul qutisini ochish.

| Ulanish turi | Qaysi qurilmada | "Manzil" maydoniga nima yoziladi |
|---|---|---|
| **Tarmoq (Wi-Fi/LAN)** | Hammasida (eng ishonchli) | Printer IP manzili, port `9100` |
| **Bluetooth** | Android (klassik BT), iOS (faqat BLE printer), Windows/macOS | Printer tanlanadi (🔍 qidirish) yoki MAC manzil |
| **Tizim printeri (USB)** | Windows, macOS, Linux | Windows: printer nomi (Панель управления → Принтеры). macOS/Linux: CUPS nomi yoki `/dev/usb/lp0` |

### 7.1. USB printer (Windows)
1. Printer drayverini o'rnating (printer bilan kelgan disk yoki ishlab chiqaruvchi sayti;
   Xprinter, Rongta, HPRT, Epson TM va h.k.). Drayver yo'q bo'lsa — "Generic / Text Only" drayveri.
2. *Settings → Bluetooth & devices → Printers & scanners* da printerning **aniq nomini** ko'ring
   (masalan `XP-80C`).
3. Ilovada: Ulanish turi **Tizim printeri** → Manzil: `XP-80C` → kenglik `80 mm` → **Saqlash** →
   **Sinov cheki**.

Ilova chekni printerga **RAW (to'g'ridan-to'g'ri ESC/POS)** ko'rinishida yuboradi, shuning uchun
drayverdagi shrift/masshtab sozlamalari ta'sir qilmaydi.

### 7.2. USB printer (macOS / Linux)
1. Printerni CUPS'ga qo'shing: `http://localhost:631` → *Administration → Add Printer* →
   model: **Raw Queue**. Nomini eslab qoling (masalan `XP80`).
2. Ilovada: **Tizim printeri** → Manzil: `XP80` → **Sinov cheki**.
3. Linux'da muqobil: Manzil `/dev/usb/lp0` (foydalanuvchi `lp` guruhida bo'lishi kerak).

### 7.3. Bluetooth printer (Android)
1. Telefon **Sozlamalar → Bluetooth** da printerni juftlang (PIN odatda `0000` yoki `1234`).
2. Ilovada: Ulanish turi **Bluetooth** → 🔍 → printerni tanlang → **Sinov cheki**.
3. Ikki Bluetooth printer bo'lsa, ilova ular orasida navbat bilan ulanadi (bir vaqtda faqat bitta
   BT ulanish bo'lishi mumkin), chek ikkalasiga ham chiqadi.

### 7.4. Wi-Fi / LAN printer
1. Printerni o'chirib, **FEED** tugmasini bosib turgan holda yoqing — o'z-o'zini sinash cheki
   chiqadi, unda IP manzil yozilgan (masalan `192.168.1.87`).
2. Printer IP'si do'kon tarmog'iga mos bo'lmasa, ishlab chiqaruvchi utilitasi bilan o'zgartiring.
3. Ilovada: **Tarmoq** → IP `192.168.1.87`, port `9100` → **Sinov cheki**.

### 7.5. Telefondan kompyuter printeriga (server orqali)
Telefon chekni Bluetooth'siz, **PosServer.exe** orqali kompyuterga ulangan printerdan chiqaradi
(Wi-Fi yoki Tailscale orqali — internet bo'lsa boshqa joydan ham).
1. Printer kompyuterga ulangan va Windows'ga o'rnatilgan bo'lsin, PosServer.exe ishlab tursin.
2. Telefonda sinxronlash ulangan bo'lsin (**Sozlamalar → Sinxronlash**, "Ulanishni tekshirish").
3. **Sozlamalar → Printerlar → 1-printer** → Ulanish turi: **Kompyuter printeri (server orqali)**.
4. 🔍 tugmasini bosing — kompyuterdagi printerlar chiqadi, keraklisini tanlang → **Sinov cheki**.

### 7.6. Tovar yorlig'i (shtrix/QR-kod, kompyuterda)
Tovar kartasida shtrix-kod yonidagi 🖨 tugmasi: shtrix yoki QR, soni, o'lcham, nom va narx tanlanadi.
Standart holatda **2-printer**ga chiqadi (USB/Windows printeri — PDF, termoprinter — ESC/POS).

### 7.7. Chek matni
Ko'p arzon termoprinterlarda o'zbek harflari (oʻ, gʻ) yo'q. Ilova chekdagi matnni avtomatik
oddiy lotin harflariga (o', g') o'giradi, shuning uchun chek har qanday printerda to'g'ri chiqadi.
Do'kon nomi, manzil, telefon, STIR va chek pastidagi matn: **Sozlamalar → Do'kon va chek**.

---

## 8. Shtrix-kod skanerlari (2 tagacha)

### 8.1. USB skaner (kompyuter)
Oddiy USB skaner "klaviatura" kabi ishlaydi — hech qanday drayver yoki sozlash kerak emas.
1. Skanerni USB'ga ulang.
2. Skaner **Enter** (CR) suffiksi bilan sozlangan bo'lsin (deyarli barchasi zavoddan shunday;
   bo'lmasa skaner qo'llanmasidagi "Add CR suffix" shtrix-kodini skanerlang).
3. Kassa ekranida istalgan tovarni skanerlang — u savatga tushadi. Qidiruv maydoni fokusda
   bo'lmasa ham ishlaydi: ilova tez kiritilgan belgilarni (60 ms dan tez) skaner deb taniydi.

**Ikkita skaner** (masalan, biri kassada, biri qo'lda yoki omborda) — ikkalasini ham USB'ga ulang,
ikkalasi bir vaqtda ishlaydi. Qo'shimcha sozlash kerak emas.

### 8.2. Bluetooth skaner
1. Skanerni **HID (klaviatura) rejimiga** o'tkazing (skaner qo'llanmasidagi "Bluetooth HID" shtrix-kodi).
2. Kompyuter yoki telefon Bluetooth sozlamalarida juftlang.
3. Shundan keyin USB skaner kabi ishlaydi. Android'da ham, iOS'da ham ishlaydi.

> Android'da Bluetooth skaner ulanganda ekran klaviaturasi yo'qolishi mumkin — bu normal holat.

### 8.3. Telefon kamerasi
Android, iOS va macOS'da qidiruv maydonidagi 📷 tugmasi kamerani ochadi. EAN-13, EAN-8, UPC,
Code128, QR va boshqa formatlar qo'llanadi.

### 8.4. Omborga kirim skaner bilan
**Ombor → Kirim (skaner)** bo'limida tovarlarni ketma-ket skanerlang (har skanerlash +1),
miqdor va kirim narxini tuzating → **Omborga qabul qilish**. Bazada yo'q shtrix-kod skanerlansa,
ilova shu kod bilan yangi tovar kartasini ochishni taklif qiladi.

### 8.5. Firmadan kirim, prays-list va qarzlar

1. **Ombor → Kirim**: "Firma" maydonidan firmani tanlang (yo'q bo'lsa — "Yangi firma"), nakladnoy raqami va sanasini kiriting.
2. Firma tanlangach **"Prays-listni suratga olish"** tugmasi chiqadi — bir nechta sahifani suratga olish mumkin.
3. Tovarlarni skanerlang, soni va kirim narxini kiriting → **"Omborga qabul qilish"**.
4. Oynada **"Hozir to'lanadi"** ga kassada borini yozing — qolgani avtomatik **qarzga** yoziladi.

**Qarzlar** bo'limi (Admin va Omborchi): tepada umumiy qarzdorlik, pastda firmalar (eng ko'p qarz tepada).
Firmani bossangiz — kirimlar (prays-list suratlari bilan), to'lovlar tarixi va akt-sverka (har qadamdagi qoldiq).
Kirimni bossangiz — tovarlar, soni, narxi va suratlar. Qarzni istalgan payt qisman yoki to'liq to'lash mumkin;
to'lovlar eng eski kirimdan boshlab yopadi. Firmalar, kirimlar, to'lovlar va suratlar barcha qurilmalarga sinxronlanadi
(buning uchun PosServer.exe ham yangi versiyaga almashtirilishi kerak).

**Firma sizga qarz bo'lsa.** Prays-list bo'yicha to'lab, tovarning bir qismi kelmasa (yoki tovar firmaga qaytarilsa):
kirim sahifasida **"Kam keldi / firmaga qaytarish"** — tovar va miqdorni tanlang, tovar ombordan ayriladi va summasi
qarzdan chegiriladi. Faqat summa bo'yicha — firma sahifasida **"Kam kelgan tovar"**. Qarz minusga o'tsa, firma sizga
qarz deb ko'rsatiladi (yashil); firma pulni qaytarganda **"Firmadan pul olish"**.

**Agent imzosi.** Har bir to'lovda (va kirim paytidagi to'lovda) agent ismini yozing va **"Imzo qo'ydirish"** tugmasini
bosing — agent barmog'i bilan telefon ekraniga imzo chekadi. Imzo to'lovlar ro'yxatida ko'rinadi (bosilsa kattalashadi)
va boshqa qurilmalarga ham o'tadi.

### 8.6. Filiallar

**Sozlamalar → Filiallar** (faqat bosh admin) bo'limida filial qo'shiladi. Filial ikkita va undan ko'p
bo'lsa, yuqori panelning chap tomonida **filial tanlagich** paydo bo'ladi.

- **Tovarlar, shtrix-kodlar, kategoriyalar va firmalar** — hamma filialda bir xil (bir marta kiritiladi).
- **Savdo tarixi, ombordagi qoldiq, kirimlar, firmalarga qarz, dashboard, mavsumiy statistika va
  o'zgarishlar jurnali** — har bir filialda **alohida**. Filialni almashtirsangiz, shu filialniki ko'rinadi.
- Har bir kassa (qurilma) qaysi filialda ishlasa, o'sha filial tanlab qo'yiladi — savdo shu filialga yoziladi.
- Tovar kartasida boshqa filiallardagi qoldiq ham ko'rinadi.

**Ruxsatlar.** **Xodimlar** bo'limida xodimni ochib, "Barcha filiallarda shu rol" ni o'chirsangiz, har bir filial
uchun alohida rol (Admin / Kassir / Omborchi yoki "Ruxsat yo'q") tanlanadi. Masalan, kassir faqat o'z
filialida ishlaydi; filial mudiri faqat o'z filialida Admin. Filiallar va xodimlarni faqat **bosh admin**
(barcha filiallarda Admin) boshqaradi. Xodim ruxsati bo'lmagan filialdagi qurilmaga kirsa, dastur uni
ruxsati bor filialga o'tkazadi.

> Filiallar ishlashi uchun **barcha qurilmalardagi ilovani va PosServer.exe ni yangilang** (eski server
> filiallar ro'yxatini qabul qilmaydi).

### 8.7. O'zgarishlar jurnali

**O'zgarishlar** bo'limida (Admin va Omborchi) tanlangan kunda dasturda nima bo'lgani ko'rinadi:
qo'shilgan, o'zgartirilgan va o'chirilgan tovarlar, narx o'zgarishlari (eski → yangi narx), omborga kirim,
hisobdan chiqarish va firmaga qaytarish, inventarizatsiya, savdo va qaytarilgan cheklar, firmalarga
to'lovlar, xodim va filial o'zgarishlari — kim va qachon qilgani bilan. Yuqorida kunlik yig'indi raqamlar,
pastda to'liq ro'yxat (turi bo'yicha filtrlash mumkin). Monitoring sahifasida bugungi oxirgi o'zgarishlar ham chiqadi.

---

## 9. Birinchi ishga tushirish

1. Ilovani oching. Kirish: **login `admin`, parol `admin123`**.
2. **Darhol parolni o'zgartiring:** yuqori o'ng burchakdagi profil belgisi → *Parolni o'zgartirish*.
3. **Sozlamalar → Do'kon va chek**: do'kon nomi, manzil, telefon, STIR, **Kassa (qurilma) kodi**.
4. **Xodimlar**: kassir va omborchilarni qo'shing (har biriga alohida login).

| Rol | Imkoniyatlar |
|---|---|
| **Admin** | Hammasi: dashboard, sozlamalar, xodimlar, chekni qaytarish, 20% dan katta chegirma |
| **Kassir** | Savdo, 20% gacha chegirma, savdo tarixi (faqat o'z cheklari), chekni qayta chop etish, alertlar |
| **Omborchi** | Ombor (tovarlar, kirim, hisobdan chiqarish, qaytarish, qoldiqlar, kategoriyalar), mavsumiy tahlil, alertlar |

Kassir 20% dan katta chegirma bermoqchi bo'lsa, ilova **admin parolini** so'raydi —
admin shu joyning o'zida tasdiqlaydi.

5. **Ombor → Kategoriyalar**: tayyor kategoriyalar bor, keragini qo'shing.
6. **Ombor → Yangi tovar**: tovarlarni kiriting (yoki **Kirim (skaner)** orqali).
   Har bir tovar uchun **minimal qoldiq** kiriting — undan kam qolsa alert chiqadi.
   Mavsumiy tovarlarga **mavsum** belgisini qo'ying (qish, bahor, yoz, kuz) — ular
   "Mavsumiy tavsiyalar" panelida ko'rinadi.
7. **Sozlamalar → Alertlar**: kunlik savdo maqsadi, anomal chek chegarasi.
8. **Sozlamalar → Printerlar**: 7-bo'lim.

### Demo ma'lumotlar
Tizimni sinab ko'rish uchun: **Sozlamalar → Ma'lumotlar → Demo ma'lumotlarni yuklash** —
42 ta tovar va ~14 oylik savdo tarixi yaratiladi (dashboard, mavsumiy tahlil va alertlarni
ko'rish uchun). **Haqiqiy ish boshlashdan oldin** ilovani qayta o'rnating yoki baza faylini
o'chiring (2–4-bo'limlardagi yo'llar), shunda toza baza bilan boshlanadi.

---

## 10. Kundalik ish: tezkor tugmalar (kompyuter)

| Tugma | Amal |
|---|---|
| **F2** | Qidiruvga o'tish |
| **Enter** | Qidiruvda tanlangan tovarni savatga qo'shish |
| **F4** | Chegirma |
| **F8** | Savatni tozalash |
| **F9** | Tez naqd to'lov (qaytimsiz) |
| **F12** | To'lov oynasi |
| To'lov oynasida **F1/F2/F3/F4** | Naqd / Karta / O'tkazma / Aralash |
| **Enter** / **Esc** | Tasdiqlash / bekor qilish |

---

## 11. Muammolar va yechimlar

| Muammo | Yechim |
|---|---|
| Sinov cheki chiqmayapti (tarmoq) | Kompyuter va printer bitta tarmoqdami? `ping 192.168.1.87`. Port 9100. |
| Sinov cheki chiqmayapti (USB, Windows) | Printer nomi Windows'dagi bilan **aynan** bir xilmi? Windows'dan "Test page" chiqadimi? |
| Chekda "?" yoki g'alati belgilar | Printer kodlash jadvali — printerni zavod sozlamasiga qaytaring; ilova faqat lotin harflarini yuboradi. |
| Bluetooth printer topilmayapti | Avval telefon Bluetooth sozlamalarida juftlang; ilovaga "Yaqin atrofdagi qurilmalar" ruxsatini bering. |
| Skaner belgilarni chalkashtirib yozadi | Klaviatura tili **lotin (EN/US)** bo'lsin; skaner Enter suffiksi yoqilgan bo'lsin. |
| Sinxronlash: "API kalit noto'g'ri" | Ilovadagi kalit `.env` dagi `POS_API_KEY` bilan bir xil bo'lsin. |
| Sinxronlash: telefon serverga ulanmaydi | Bir Wi-Fi'dami? Firewall 8000-portni ochganmi? Brauzerda `http://IP:8000/api/health` ochiladimi? |
| Qoldiq noto'g'ri ko'rinadi | **Sozlamalar → Ma'lumotlar → Qoldiqlarni qayta hisoblash** (harakatlar jurnalidan qayta hisoblaydi). |
| Ikki qurilmada bir tovar narxi turlicha o'zgartirildi | Oxirgi o'zgartirilgan narx g'olib bo'ladi (bu kutilgan xatti-harakat). |

---

## 12. Yangilash

1. Yangi versiyani o'rnatishdan oldin baza faylining zaxira nusxasini oling.
2. Android: yangi APK'ni ustidan o'rnating (ma'lumotlar saqlanadi, agar bir xil kalit bilan imzolangan bo'lsa).
3. Windows/Linux/macOS: eski papkani yangisi bilan almashtiring — baza boshqa joyda saqlangani uchun yo'qolmaydi.
4. Server: `git pull` (yoki yangi fayllar) → `docker compose up -d --build`.
