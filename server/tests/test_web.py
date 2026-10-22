"""Web hisobot paneli testlari."""

import json
import time

from app import web
from app.web import DEFAULT_BRANCH_ID

from .test_sync import H, client, fresh_db, push  # noqa: F401

SALT = "c2FsdC1zYWx0"
# Ilovadagi PasswordHasher.hash('admin123', SALT) — app/test/core_test.dart ham tekshiradi.
HASH = "WsSn7hSEnQkDNa6kbkYPPMlODSkg_W8tojHw5dLlxiI="
B2 = "branch-2"


def rec(entity, rid, **data):
    return {"entity": entity, "id": rid, "data": {"id": rid, "updated_at": 1000, **data}}


def user(uid, username, role="admin", branch_roles=""):
    return rec("users", uid, username=username, full_name=username.title(), role=role,
               password_hash=HASH, salt=SALT, is_active=1, branch_roles=branch_roles)


def ms(day: str, hour: int = 12) -> int:
    return int(time.mktime(time.strptime(f"{day} {hour}", "%Y-%m-%d %H")) * 1000)


def seed(client):
    push(client, [
        user("u1", "admin"),
        user("u2", "kassir", role="cashier"),
        user("u3", "filial", role="cashier", branch_roles=json.dumps({B2: "admin"})),
        rec("branches", DEFAULT_BRANCH_ID, name="Asosiy", sort_order=0),
        rec("branches", B2, name="Chilonzor", sort_order=1),
        rec("products", "p1", name="Chelak", unit="dona", sale_price=20000, purchase_price=12000, min_stock=5),
        rec("stock_movements", "m1", product_id="p1", qty=10, type="receipt"),
        rec("stock_movements", "m2", product_id="p1", qty=-7, type="sale"),
        rec("stock_movements", "m3", product_id="p1", qty=4, type="receipt", branch_id=B2),
        rec("sales", "s1", receipt_no="K1-1", created_at=ms("2026-10-20"), total=40000, cost_total=24000,
            status="completed", payment_type="cash", paid_cash=50000, change_amount=10000, cashier_name="Ali"),
        rec("sale_items", "i1", sale_id="s1", product_id="p1", product_name="Chelak", qty=2, price=20000, line_total=40000),
        rec("sales", "s2", receipt_no="K2-1", created_at=ms("2026-10-20"), total=30000, cost_total=20000,
            status="completed", payment_type="debt", debt_amount=30000, cashier_name="Vali", branch_id=B2),
        rec("sales", "s3", receipt_no="K1-2", created_at=ms("2026-10-21"), total=5000, status="refunded"),
        rec("suppliers", "f1", name="Firma"),
        rec("supplier_purchases", "sp1", supplier_id="f1", total=100000, kind="purchase"),
        rec("supplier_payments", "pay1", supplier_id="f1", amount=60000),
        rec("customers", "c1", name="Mijoz"),
        rec("customer_debts", "d1", customer_id="c1", amount=30000, kind="sale", branch_id=B2, created_at=1),
        rec("audit_log", "a1", action="price_changed", details="Chelak", user_name="Admin", created_at=ms("2026-10-20")),
        rec("audit_log", "a2", action="login", user_name="Admin", created_at=ms("2026-10-20"), branch_id=""),
    ])


def login(client, username="admin", password="admin123"):
    return client.post("/api/web/login", json={"username": username, "password": password})


def test_page_and_login_required(client):
    assert client.get("/", follow_redirects=False).headers["location"] == "/panel"
    assert "POS hisobot" in client.get("/panel").text
    assert client.get("/api/web/me").status_code == 401


def test_login_rules(client):
    seed(client)
    assert login(client, password="xato").status_code == 401
    assert login(client, "kassir").status_code == 403
    assert login(client, "ADMIN").status_code == 200
    me = client.get("/api/web/me").json()
    assert me["owner"] and [b["name"] for b in me["branches"]] == ["Asosiy", "Chilonzor"]
    client.post("/api/web/logout")
    client.cookies.clear()
    assert client.get("/api/web/me").status_code == 401
    # API kalit bilan (xodimlar hali sinxronlanmagan bo'lsa).
    assert login(client, "admin", "test-key").status_code == 200


def test_tampered_token_rejected():
    tok = web.make_token("u1")
    assert web.read_token(tok) == "u1"
    assert web.read_token(tok[:-1] + ("0" if tok[-1] != "0" else "1")) is None
    assert web.read_token(web.make_token("u1", now=time.time() - web.TOKEN_TTL - 5)) is None


def test_overview(client):
    seed(client)
    login(client)
    d = client.get("/api/web/overview", params={"date_from": "2026-10-20", "date_to": "2026-10-21"}).json()
    assert d["total"] == 70000 and d["count"] == 2 and d["profit"] == 26000
    assert d["payments"] == {"cash": 40000, "card": 0, "transfer": 0, "debt": 30000}
    assert d["refunds"] == 1 and d["refund_sum"] == 5000
    assert d["top_products"][0] == {"name": "Chelak", "unit": "", "qty": 2.0, "total": 40000}
    one = client.get("/api/web/overview", params={"date_from": "2026-10-20", "branch_id": B2}).json()
    assert one["total"] == 30000


def test_stock_debts_activity(client):
    seed(client)
    login(client)
    p = client.get("/api/web/stock").json()["products"][0]
    assert p["qty"] == 7 and p["by_branch"] == {DEFAULT_BRANCH_ID: 3, B2: 4}
    assert client.get("/api/web/stock", params={"branch_id": DEFAULT_BRANCH_ID}).json()["products"][0]["low"]
    d = client.get("/api/web/debts").json()
    assert d["supplier_debt"] == 40000 and d["customer_debt"] == 30000
    a = client.get("/api/web/activity", params={"date_from": "2026-10-20"}).json()
    assert {x["action"] for x in a["log"]} == {"price_changed", "login"}
    assert a["devices"]


def test_branch_admin_sees_only_own_branch(client):
    seed(client)
    assert login(client, "filial").status_code == 200
    me = client.get("/api/web/me").json()
    assert not me["owner"] and [b["id"] for b in me["branches"]] == [B2]
    d = client.get("/api/web/overview", params={"date_from": "2026-10-20"}).json()
    assert d["total"] == 30000
    assert client.get("/api/web/sales", params={"date_from": "2026-10-20", "branch_id": DEFAULT_BRANCH_ID}).status_code == 403
    assert client.get("/api/web/debts").json()["supplier_debt"] == 0
    a = client.get("/api/web/activity", params={"date_from": "2026-10-20"}).json()
    assert a["log"] == [] and a["devices"] == []
