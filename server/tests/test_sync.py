"""Sinxronlash serveri testlari (SQLite xotirada)."""

import os

os.environ["POS_DATABASE_URL"] = "sqlite:///./test_pos.db"
os.environ["POS_API_KEY"] = "test-key"

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
