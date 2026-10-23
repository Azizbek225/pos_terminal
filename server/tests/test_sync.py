"""Sinxronlash serveri testlari (SQLite xotirada)."""

import os

os.environ["POS_DATABASE_URL"] = "sqlite:///./test_pos.db"
os.environ["POS_API_KEY"] = "test-key"
os.environ["POS_IMAGES_DIR"] = "./test_images"

import pytest
from fastapi.testclient import TestClient

from app.db import Base, engine
from app.main import app

H = {"X-API-Key": "test-key", "X-Device-Id": "dev-a"}


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def product(pid="p1", updated=1000, name="Chelak", dev="dev-a"):
    return {"entity": "products", "id": pid, "data": {"id": pid, "name": name, "updated_at": updated, "device_id": dev}}


def push(client, changes, dev="dev-a"):
    r = client.post("/api/sync/push", json={"device_id": dev, "changes": changes}, headers={**H, "X-Device-Id": dev})
    assert r.status_code == 200, r.text
    return r.json()


def test_health(client):
    assert client.get("/api/health").json()["status"] == "ok"


def test_auth_required(client):
    assert client.get("/api/sync/pull").status_code == 401
    assert client.get("/api/sync/pull", headers={"X-API-Key": "wrong"}).status_code == 401


def test_push_then_pull_with_cursor(client):
    res = push(client, [product("p1"), product("p2")])
    assert len(res["accepted"]) == 2
    pulled = client.get("/api/sync/pull?since=0&limit=1", headers=H).json()
    assert pulled["has_more"] is True and len(pulled["changes"]) == 1
    nxt = client.get(f"/api/sync/pull?since={pulled['cursor']}", headers=H).json()
    assert [c["id"] for c in nxt["changes"]] == ["p2"]
    assert nxt["has_more"] is False


def test_last_write_wins_and_conflict_returns_server_version(client):
    push(client, [product(updated=2000, name="Yangi nom", dev="dev-b")], dev="dev-b")
    res = push(client, [product(updated=1500, name="Eski nom")])
    assert res["accepted"] == []
    assert res["conflicts"][0]["data"]["name"] == "Yangi nom"
    res = push(client, [product(updated=3000, name="Eng yangi")])
    assert len(res["accepted"]) == 1
    data = client.get("/api/sync/pull?since=0", headers=H).json()["changes"]
    assert data[-1]["data"]["name"] == "Eng yangi"


def test_retry_of_same_version_is_idempotent(client):
    push(client, [product(updated=1000)])
    res = push(client, [product(updated=1000)])
    assert len(res["accepted"]) == 1 and res["conflicts"] == []


def test_immutable_movements_are_additive(client):
    mv = lambda mid, q: {"entity": "stock_movements", "id": mid, "data": {"id": mid, "product_id": "p1", "qty": q, "updated_at": 1}}
    push(client, [mv("m1", -2)], dev="dev-a")
    push(client, [mv("m2", -3)], dev="dev-b")
    push(client, [mv("m1", -2)], dev="dev-a")  # takroriy
    rows = [c for c in client.get("/api/sync/pull?since=0", headers=H).json()["changes"] if c["entity"] == "stock_movements"]
    assert sum(r["data"]["qty"] for r in rows) == -5


def test_refund_always_wins(client):
    sale = lambda status, upd: {"entity": "sales", "id": "s1", "data": {"id": "s1", "status": status, "updated_at": upd}}
    push(client, [sale("completed", 1000)])
    push(client, [sale("refunded", 1100)], dev="dev-b")
    res = push(client, [sale("completed", 5000)])
    assert res["conflicts"][0]["data"]["status"] == "refunded"


def test_invalid_entity_rejected(client):
    res = push(client, [{"entity": "hack", "id": "x", "data": {"id": "x"}}])
    assert res["rejected"][0]["reason"] == "invalid"


def test_daily_report(client):
    from datetime import datetime

    ts = int(datetime(2026, 10, 4, 12, 0).timestamp() * 1000)
    s = {"entity": "sales", "id": "s9", "data": {"id": "s9", "status": "completed", "total": 50000, "created_at": ts, "updated_at": ts, "cashier_name": "Ali"}}
    push(client, [s])
    r = client.get("/api/reports/daily?date_from=2026-10-01&date_to=2026-10-31", headers=H).json()
    assert r["total"] == 50000 and r["count"] == 1 and r["by_cashier"]["Ali"] == 50000


def test_images_roundtrip(client):
    name = "1b2c3d4e-0000-4000-8000-000000000001.jpg"
    assert client.put(f"/api/images/{name}", content=b"\xff\xd8jpegdata", headers=H).status_code == 200
    assert name in client.get("/api/images", headers=H).json()["names"]
    r = client.get(f"/api/images/{name}", headers=H)
    assert r.status_code == 200 and r.content == b"\xff\xd8jpegdata"
    assert client.get("/api/images/yoq.jpg", headers=H).status_code == 404
    assert client.put("/api/images/..%2Fevil.jpg", content=b"x", headers=H).status_code in (400, 404)
    assert client.put("/api/images/evil.exe", content=b"x", headers=H).status_code == 400
    assert client.get("/api/images", headers={"X-API-Key": "notogri"}).status_code == 401


def test_pull_reports_max_seq(client):
    push(client, [product("p1"), product("p2")])
    r = client.get("/api/sync/pull?since=0", headers=H).json()
    assert r["max_seq"] == 2


def test_server_id_stable(client):
    a = client.get("/api/health").json()["server_id"]
    assert a and client.get("/api/health").json()["server_id"] == a
    assert client.get("/api/sync/pull?since=0", headers=H).json()["server_id"] == a


def test_supplier_entities_sync(client):
    rec = lambda e, rid, **d: {"entity": e, "id": rid, "data": {"id": rid, "updated_at": 1000, "device_id": "dev-a", **d}}
    res = push(client, [
        rec("suppliers", "s1", name="Gigiena MChJ"),
        rec("supplier_purchases", "sp1", supplier_id="s1", total=500000),
        rec("supplier_purchase_items", "spi1", purchase_id="sp1", qty=10, price=50000),
        rec("supplier_payments", "pay1", supplier_id="s1", amount=200000),
    ])
    assert len(res["accepted"]) == 4 and not res["rejected"]
    # Kirim qatori o'zgarmas: qayta yuborilgan boshqa versiya ham serverdagini o'zgartirmaydi.
    changed = rec("supplier_purchase_items", "spi1", purchase_id="sp1", qty=99, price=1)
    changed["data"]["updated_at"] = 2000
    push(client, [changed])
    pulled = client.get("/api/sync/pull?since=0", headers=H).json()["changes"]
    item = next(c for c in pulled if c["id"] == "spi1")
    assert item["data"]["qty"] == 10
    assert {c["entity"] for c in pulled} == {"suppliers", "supplier_purchases", "supplier_purchase_items", "supplier_payments"}


def test_print_via_server(client, monkeypatch):
    from app import printers

    sent = []
    monkeypatch.setattr(printers, "list_printers", lambda: ["XP-80C", "Label"])
    monkeypatch.setattr(printers, "print_raw", lambda name, data, doc_name="": sent.append((name, data)))

    assert client.get("/api/printers").status_code == 401
    assert client.get("/api/printers", headers=H).json() == {"printers": ["XP-80C", "Label"]}

    r = client.post("/api/print", params={"printer": "XP-80C"}, content=b"\x1b@chek", headers=H)
    assert r.status_code == 200, r.text
    assert sent == [("XP-80C", b"\x1b@chek")]
    assert client.post("/api/print", params={"printer": "XP-80C"}, content=b"", headers=H).status_code == 400

    def fail(name, data, doc_name=""):
        raise printers.PrintError('Printer topilmadi: "Yo\'q"')

    monkeypatch.setattr(printers, "print_raw", fail)
    r = client.post("/api/print", params={"printer": "Yo'q"}, content=b"x", headers=H)
    assert r.status_code == 502 and "topilmadi" in r.json()["detail"]


def test_concurrent_pushes_get_unique_seq(client):
    """Bir vaqtda bir nechta qurilma yuborsa ham xato yo'q va seq takrorlanmaydi."""
    import threading

    errors = []

    def dev(n):
        for b in range(5):
            changes = [product(f"{n}-{b}-{i}") for i in range(50)]
            r = client.post("/api/sync/push", json={"device_id": f"d{n}", "changes": changes},
                            headers={**H, "X-Device-Id": f"d{n}"})
            if r.status_code != 200:
                errors.append(r.text)

    threads = [threading.Thread(target=dev, args=(n,)) for n in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    pulled = client.get("/api/sync/pull", params={"since": 0, "limit": 5000}, headers=H).json()["changes"]
    assert len(pulled) == 1000
    assert len({c["seq"] for c in pulled}) == 1000


def test_migrate_fills_report_columns():
    """Eski bazaga ts/ref ustunlari qo'shiladi va mavjud yozuvlardan to'ldiriladi."""
    from sqlalchemy import create_engine, text

    from app import sync

    eng = create_engine("sqlite://")
    with eng.begin() as conn:
        conn.execute(text(
            "CREATE TABLE sync_records (entity VARCHAR(40), id VARCHAR(64), data JSON, updated_at BIGINT, "
            "device_id VARCHAR(64), deleted BOOLEAN, seq BIGINT, received_at BIGINT, PRIMARY KEY (entity, id))"
        ))
        conn.execute(text(
            "INSERT INTO sync_records VALUES ('sale_items', 'i1', '{\"sale_id\": \"s1\", \"created_at\": 5}', 1, '', 0, 1, 1)"
        ))
    sync.migrate(eng)
    sync.migrate(eng)  # ikkinchi marta — hech narsa qilmaydi
    with eng.connect() as conn:
        assert conn.execute(text("SELECT ts, ref FROM sync_records")).one() == (5, "s1")
