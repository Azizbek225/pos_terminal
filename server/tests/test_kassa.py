"""Web kassa testlari: savdo, qaytarish, kirim, tovar — ilova yozuvlari bilan bir xil."""

from .test_sync import H, client, fresh_db, push  # noqa: F401
from .test_web import B2, DEFAULT_BRANCH_ID, login, seed

A = DEFAULT_BRANCH_ID


def pulled(client, entity):
    rows = client.get("/api/sync/pull?since=0&limit=2000", headers=H).json()["changes"]
    return [c["data"] for c in rows if c["entity"] == entity]


def kassa_login(client, username="admin"):
    r = client.post("/api/kassa/login", json={"username": username, "password": "admin123"})
    assert r.status_code == 200, r.text


def stock_of(client, branch=A, pid="p1"):
    rows = client.get("/api/kassa/products", params={"branch_id": branch}).json()["products"]
    return next(p["qty"] for p in rows if p["id"] == pid)


def test_cashier_can_login_and_sees_branches(client):
    seed(client)
    assert client.get("/api/kassa/me").status_code == 401
    kassa_login(client, "kassir")
    me = client.get("/api/kassa/me").json()
    assert me["name"] == "Kassir" and {b["role"] for b in me["branches"]} == {"cashier"}
    # Kassir panelga (hisobot) kira olmaydi.
    assert client.get("/api/web/overview").status_code == 401
    kassa_login(client, "filial")
    assert [b["id"] for b in client.get("/api/kassa/me").json()["branches"]] == [B2]


def test_sale_writes_app_records(client):
    seed(client)
    kassa_login(client, "kassir")
    assert stock_of(client) == 3
    r = client.post("/api/kassa/sale", json={
        "branch_id": A, "lines": [{"product_id": "p1", "qty": 3}],
        "discount_type": "percent", "discount_value": 10, "paid_cash": 60000,
    })
    assert r.status_code == 200, r.text
    s = r.json()
    assert s["receipt_no"] == "W1-000001" and s["subtotal"] == 60000 and s["discount"] == 6000
    assert s["total"] == 54000 and s["change"] == 6000 and s["items"][0]["total"] == 54000
    assert stock_of(client) == 0

    sale = next(x for x in pulled(client, "sales") if x["id"] == s["id"])
    assert sale["status"] == "completed" and sale["cashier_name"] == "Kassir" and sale["cost_total"] == 36000
    assert sale["payment_type"] == "cash" and sale["branch_id"] == A
    mv = [m for m in pulled(client, "stock_movements") if m.get("ref_id") == s["id"]]
    assert [(m["type"], m["qty"]) for m in mv] == [("sale", -3)]
    # Ikkinchi chek — keyingi raqam.
    r = client.post("/api/kassa/sale", json={"branch_id": A, "lines": [{"product_id": "p1", "qty": 1}], "paid_card": 20000})
    assert r.json()["receipt_no"] == "W1-000002" and r.json()["payment"] == "card"


def test_sale_rules(client):
    seed(client)
    kassa_login(client, "kassir")
    base = {"branch_id": A, "lines": [{"product_id": "p1", "qty": 1}]}
    assert client.post("/api/kassa/sale", json={**base, "paid_cash": 10000}).status_code == 422
    big = {**base, "discount_type": "percent", "discount_value": 30, "paid_cash": 20000}
    assert client.post("/api/kassa/sale", json=big).status_code == 403
    assert client.post("/api/kassa/sale", json={**base, "debt": 20000}).status_code == 422
    assert client.post("/api/kassa/sale", json={**base, "branch_id": "boshqa", "paid_cash": 20000}).status_code == 403
    kassa_login(client)
    assert client.post("/api/kassa/sale", json=big).status_code == 200


def test_debt_sale_refund_and_payment(client):
    seed(client)
    kassa_login(client)
    c = client.post("/api/kassa/customers", json={"branch_id": A, "name": "Anvar"}).json()
    s = client.post("/api/kassa/sale", json={
        "branch_id": A, "lines": [{"product_id": "p1", "qty": 2}], "paid_cash": 10000, "debt": 30000,
        "customer_id": c["id"],
    }).json()
    assert s["payment"] == "debt" and s["debt"] == 30000
    debts = {x["id"]: x["debt"] for x in client.get("/api/kassa/customers", params={"branch_id": A}).json()["customers"]}
    assert debts[c["id"]] == 30000
    r = client.post("/api/kassa/customer_payment", json={"branch_id": A, "customer_id": c["id"], "amount": 5000})
    assert r.json()["debt"] == 25000

    kassa_login(client, "kassir")
    assert client.post("/api/kassa/refund", json={"sale_id": s["id"]}).status_code == 403
    kassa_login(client)
    assert client.post("/api/kassa/refund", json={"sale_id": s["id"], "reason": "singan"}).json()["status"] == "refunded"
    assert client.post("/api/kassa/refund", json={"sale_id": s["id"]}).status_code == 409
    assert stock_of(client) == 3
    debts = {x["id"]: x["debt"] for x in client.get("/api/kassa/customers", params={"branch_id": A}).json()["customers"]}
    assert debts[c["id"]] == -5000
    today = client.get("/api/kassa/sales", params={"branch_id": A}).json()["sales"]
    assert today[0]["status"] == "refunded" and today[0]["items"][0]["qty"] == 2
    assert {a["action"] for a in pulled(client, "audit_log")} >= {"refund", "customer_payment", "customer_saved", "login"}


def test_stock_in_and_products(client):
    seed(client)
    kassa_login(client, "kassir")
    assert client.post("/api/kassa/stock_in", json={"branch_id": A, "lines": [{"product_id": "p1", "qty": 5}]}).status_code == 403
    kassa_login(client)
    r = client.post("/api/kassa/stock_in", json={"branch_id": A, "lines": [{"product_id": "p1", "qty": 5, "unit_cost": 13000}]})
    assert r.json()["qty"] == {"p1": 8}
    p = next(x for x in pulled(client, "products") if x["id"] == "p1")
    assert p["purchase_price"] == 13000 and p["name"] == "Chelak"  # boshqa maydonlar saqlanadi

    new = client.post("/api/kassa/product", json={"branch_id": A, "name": "Supurgi", "barcode": "478", "sale_price": 15000}).json()
    assert new["qty"] == 0 and new["sale_price"] == 15000
    dup = client.post("/api/kassa/product", json={"branch_id": A, "name": "Boshqa", "barcode": "478"})
    assert dup.status_code == 409
    upd = client.post("/api/kassa/product", json={"branch_id": A, "id": new["id"], "name": "Supurgi", "barcode": "478", "sale_price": 16000})
    assert upd.json()["sale_price"] == 16000
    actions = [a["action"] for a in pulled(client, "audit_log")]
    assert "product_created" in actions and actions.count("price_changed") == 3  # biri seed'da


def test_kassa_page(client):
    assert "Kassa" in client.get("/kassa").text
