"""Dollar: kurs manbai, web kassada dollar qarzli mijoz, panelda dollar qarzlar."""

from app import kurs

from .test_kassa import A, kassa_login, pulled
from .test_sync import H, client, fresh_db, push  # noqa: F401
from .test_web import login, rec, seed


def test_parse_cbu():
    rate, date = kurs.parse_cbu([{"Ccy": "USD", "Nominal": "1", "Rate": "12050.38", "Date": "14.11.2026"}])
    assert rate == 12050.38 and date == "2026-11-14"
    assert kurs.parse_cbu([{"Ccy": "EUR", "Rate": "1"}]) is None


def test_kurs_needs_key_and_uses_cache(client, monkeypatch):
    assert client.get("/api/kurs").status_code == 401
    calls = []
    monkeypatch.setattr(kurs, "fetch", lambda: calls.append(1) or {"rate": 12000.0, "date": "2026-11-14", "source": "cbu"})
    kurs._cache.update(at=0.0, data=None)
    assert client.get("/api/kurs", headers=H).json()["rate"] == 12000.0
    assert client.get("/api/kurs", headers=H).json()["rate"] == 12000.0
    assert len(calls) == 1


def test_web_kassa_usd_customer(client):
    seed(client)
    push(client, [
        rec("customers", "cu", name="Botir", currency="USD", is_active=1),
        rec("currency_rates", "r1", currency="USD", rate=12000, source="cbu", created_at=1000),
    ])
    kassa_login(client)
    s = client.post("/api/kassa/sale", json={
        "branch_id": A, "lines": [{"product_id": "p1", "qty": 1}], "debt": 20000, "customer_id": "cu",
    })
    assert s.status_code == 200, s.text
    d = [x for x in pulled(client, "customer_debts") if x["customer_id"] == "cu"]
    assert [x["amount"] for x in d] == [167]  # 20 000 / 12 000 = $1.67 (sentda)
    rows = client.get("/api/kassa/customers", params={"branch_id": A}).json()["customers"]
    botir = next(r for r in rows if r["id"] == "cu")
    assert botir["currency"] == "USD" and botir["debt_usd"] == 1.67 and botir["debt"] == 20040
    r = client.post("/api/kassa/customer_payment", json={"branch_id": A, "customer_id": "cu", "amount": 12000})
    assert r.json()["debt_usd"] == 0.67
    assert client.post("/api/kassa/refund", json={"sale_id": s.json()["id"]}).status_code == 200
    debts = [x["amount"] for x in pulled(client, "customer_debts") if x["customer_id"] == "cu"]
    assert sum(debts) == -100  # qaytarilganda aynan $1.67 ayrildi


def test_panel_shows_usd_debts_separately(client):
    seed(client)
    push(client, [
        rec("suppliers", "su", name="Import", currency="USD"),
        rec("supplier_purchases", "pu", supplier_id="su", total=5000, branch_id=A, kind="purchase"),
    ])
    login(client)
    d = client.get("/api/web/debts").json()
    imp = next(s for s in d["suppliers"] if s["name"] == "Import")
    assert imp["currency"] == "USD" and imp["debt"] == 5000
    assert d["supplier_debt_usd"] == 5000
