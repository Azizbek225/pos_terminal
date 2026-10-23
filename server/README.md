# POS Terminal — sinxronlash serveri

Bir nechta qurilma (notebook, telefon, ikkinchi kassa) orasida ma'lumot almashish uchun
ixtiyoriy server. Qurilmalar serversiz ham to'liq ishlaydi.

## Ishga tushirish (Docker)

```bash
cp .env.example .env        # POS_API_KEY va POSTGRES_PASSWORD ni o'zgartiring
docker compose up -d
curl http://localhost:8000/api/health
```

## Docker'siz

```bash
python -m venv .venv && source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8000
```
`POS_DATABASE_URL` berilmasa SQLite (`pos.db`) ishlatiladi.

## Qurilmani ulash (QR)

PosServer.exe qo'lda ochilganda brauzerda `http://localhost:8000/ulash` sahifasi
ochiladi: unda QR kod (server manzillari + API kalit). Telefonda
Sozlamalar > Sinxronlash > "QR orqali ulash" ni bosib skanerlang. Sahifa faqat
server kompyuterining o'zida yoki panelga kirgan bosh admin uchun ochiladi.

## Web hisobot paneli

Server ishlayotganda brauzerda `http://<server-IP>:8000/` oching (telefon yoki
kompyuter, bir tarmoqda yoki Tailscale orqali). Kirish: ilovadagi admin
login/paroli (xodimlar sinxronlangan bo'lishi kerak) yoki login `admin` +
API kalit. Bosh admin barcha filiallarni, filial admini faqat o'z filialini
ko'radi. Bo'limlar: Savdo, Cheklar, Qoldiq, Qarzlar (firmalar va nasiya),
O'zgarishlar. Faqat ko'rish uchun — savdo ilovada qiladi.

## API

| Endpoint | Vazifasi |
|---|---|
| `GET /api/health` | Holat (kalitsiz) |
| `POST /api/sync/push` | Qurilmadan o'zgarishlarni qabul qilish |
| `GET /api/sync/pull?since=&limit=` | `seq > since` bo'lgan yozuvlar |
| `GET /api/devices` | Ulangan qurilmalar |
| `GET /api/reports/daily?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD` | Barcha qurilmalar bo'yicha kunlik savdo |

Barcha endpointlar (`/api/health` dan tashqari) `X-API-Key` sarlavhasini talab qiladi.
Interaktiv hujjat: `http://localhost:8000/docs`.

Hisobot VIEW'lari (PostgreSQL): `docker compose exec -T db psql -U pos -d pos < sql/views.sql`.

## Testlar

```bash
pip install -r requirements-dev.txt
python -m pytest -q
```

Konflikt qoidalari va protokol: [../docs/ARXITEKTURA.md](../docs/ARXITEKTURA.md#6-sinxronlash-protokoli).
