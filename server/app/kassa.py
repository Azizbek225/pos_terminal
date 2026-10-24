"""Web kassa: savdo, qaytarish, kirim va tovarlar brauzerdan
(http://<server>:8000/kassa). Hech qanday sozlash kerak emas — faqat login.

Web'da qilingan har bir amal ilova yozadigan yozuvlar bilan aynan bir xil
(sales, sale_items, stock_movements, customer_debts, audit_log ...) va
`sync.push` orqali yoziladi: ilovalar ularni oddiy sinxronlash bilan oladi,
qoldiq ham harakatlar yig'indisidan bir xil hisoblanadi.

Ruxsatlar ilovadagi kabi: kassir — sotuv; omborchi — kirim va tovarlar;
admin — hammasi (qaytarish, 20% dan katta chegirma).
"""

from __future__ import annotations

import math
import threading
import uuid
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Cookie, Depends, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from . import sync
from .db import get_session
from .models import ServerSetting, SyncRecord
from .web import (
    DEFAULT_BRANCH_ID,
    KEY_USER,
    LoginBody,
    _branch_roles,
    _by_ref,
    _find_user,
    _in_period,
    _num,
    _range,
    _records,
    check_login,
    read_token,
    set_login_cookie,
    stock_qty,
)

PAGE = Path(__file__).resolve().parent / "static" / "kassa.html"
DEVICE_ID = "web-kassa"
RECEIPT_PREFIX = "W1"
CASHIER_MAX_DISCOUNT = 20.0
ROLE_LABELS = {"admin": "Admin", "cashier": "Kassir", "storekeeper": "Omborchi"}

router = APIRouter()
SessionDep = Annotated[Session, Depends(get_session)]

# Chek raqami va yozuvlar navbat bilan (ikki kassa bir xil raqam olmasin).
_LOCK = threading.Lock()


def _round(x: float) -> int:
    """Dart'dagi round() kabi (0.5 — noldan uzoqqa), Python'ning bank yaxlitlashi emas."""
    return int(math.floor(abs(x) + 0.5)) * (1 if x >= 0 else -1)


def _new_id() -> str:
    return str(uuid.uuid4())


# ---------------------------------------------------------------------------
#  Foydalanuvchi va ruxsatlar
# ---------------------------------------------------------------------------


class KassaUser(BaseModel):
    id: str
    name: str
    role: str
    # Bo'sh — asosiy `role` barcha filiallarda.
    branch_roles: dict[str, str] = Field(default_factory=dict)

    def role_in(self, branch_id: str) -> str | None:
        if not self.branch_roles:
            return self.role
        return self.branch_roles.get(branch_id)


def _user_of(data: dict | None, uid: str) -> KassaUser | None:
    if uid == KEY_USER:
        return KassaUser(id=KEY_USER, name="Admin", role="admin")
    if data is None or data.get("is_active") in (False, 0):
        return None
    return KassaUser(
        id=uid,
        name=data.get("full_name") or data.get("username") or "",
        role=data.get("role") or "cashier",
        branch_roles=_branch_roles(data),
    )


def kassa_user(session: SessionDep, pos_web: Annotated[str | None, Cookie()] = None) -> KassaUser:
    uid = read_token(pos_web)
    user = _user_of(_find_user(session, uid) if uid and uid != KEY_USER else None, uid) if uid else None
    if user is None:
        raise HTTPException(status_code=401, detail="Kirish kerak")
    return user


UserDep = Annotated[KassaUser, Depends(kassa_user)]


def _branches(session: Session) -> list[dict]:
    rows = sorted(
        (b for b in _records(session, "branches") if b.get("is_active") not in (False, 0)),
        key=lambda b: (int(_num(b.get("sort_order"))), b.get("name") or ""),
    )
    return [{"id": b["id"], "name": b.get("name") or ""} for b in rows] or [
        {"id": DEFAULT_BRANCH_ID, "name": "Asosiy filial"}
    ]


def _need(user: KassaUser, branch_id: str, *roles: str, session: Session | None = None) -> str:
    role = user.role_in(branch_id)
    if role is None or (session is not None and branch_id not in {b["id"] for b in _branches(session)}):
        raise HTTPException(status_code=403, detail="Bu filialga ruxsat yo'q")
    if roles and role not in roles:
        names = ", ".join(ROLE_LABELS.get(r, r) for r in roles)
        raise HTTPException(status_code=403, detail=f"Bu amal faqat: {names}")
    return role


@router.post("/api/kassa/login")
def login(body: LoginBody, session: SessionDep, request: Request, response: Response) -> dict:
    uid, data = check_login(session, body.username, body.password, request)
    user = _user_of(data, uid)
    if user is None:
        raise HTTPException(status_code=403, detail="Xodim faol emas")
    set_login_cookie(response, uid)
    if data is not None:
        _write(session, [_audit(user, "login", "Web kassa", branch_id="")])
    return {"ok": True}


@router.get("/api/kassa/me")
def me(user: UserDep, session: SessionDep) -> dict:
    branches = [{**b, "role": user.role_in(b["id"])} for b in _branches(session)]
    return {
        "id": user.id,
        "name": user.name,
        "branches": [b for b in branches if b["role"]],
        "max_discount": CASHIER_MAX_DISCOUNT,
    }


# ---------------------------------------------------------------------------
#  Yozish: ilova yozuvlari bilan bir xil shakl
# ---------------------------------------------------------------------------


def _base(now: int) -> dict:
    return {"created_at": now, "updated_at": now, "version": 1, "device_id": DEVICE_ID, "is_deleted": 0}


def _audit(user: KassaUser, action: str, details: str, *, branch_id: str, ref_id: str = "") -> tuple[str, dict]:
    return "audit_log", {
        "id": _new_id(), "user_id": user.id, "user_name": user.name, "action": action,
        "details": details, "branch_id": branch_id, "ref_id": ref_id, **_base(sync.now_ms()),
    }


def _write(session: Session, records: list[tuple[str, dict]]) -> None:
    changes = [{"entity": e, "id": d["id"], "data": d} for e, d in records]
    res = sync.push(session, DEVICE_ID, changes)
    if res.rejected or res.conflicts:
        raise HTTPException(status_code=409, detail="Yozuv saqlanmadi, sahifani yangilab qayta urinib ko'ring")


def _next_receipt(session: Session) -> str:
    row = session.get(ServerSetting, "kassa.receipt_seq")
    seq = int(row.value) + 1 if row else 1
    if row is None:
        session.add(ServerSetting(key="kassa.receipt_seq", value=str(seq)))
    else:
        row.value = str(seq)
    session.flush()
    return f"{RECEIPT_PREFIX}-{seq:06d}"


def _product(session: Session, pid: str) -> dict:
    rec = session.get(SyncRecord, ("products", pid))
    if rec is None or rec.deleted or rec.data.get("is_deleted"):
        raise HTTPException(status_code=404, detail="Tovar topilmadi")
    return dict(rec.data)


def _money(v: int) -> str:
    return f"{v:,}".replace(",", " ") + " so'm"


# ---------------------------------------------------------------------------
#  Ma'lumotlar
# ---------------------------------------------------------------------------


def _product_row(p: dict, qty: float) -> dict:
    return {
        "id": p["id"],
        "name": p.get("name") or "",
        "short_name": p.get("short_name") or "",
        "barcode": p.get("barcode") or "",
        "barcode2": p.get("barcode2") or "",
        "sku": p.get("sku") or "",
        "category_id": p.get("category_id") or "",
        "unit": p.get("unit") or "dona",
        "is_weighted": bool(p.get("is_weighted")),
        "sale_price": int(_num(p.get("sale_price"))),
        "purchase_price": int(_num(p.get("purchase_price"))),
        "min_stock": _num(p.get("min_stock")),
        "image": p.get("image_path") or "",
        "qty": round(qty, 3),
    }


@router.get("/api/kassa/products")
def products(user: UserDep, session: SessionDep, branch_id: Annotated[str, Query()]) -> dict:
    _need(user, branch_id)
    qty = stock_qty(session, {branch_id})
    rows = [
        _product_row(p, qty.get(p["id"], {}).get(branch_id, 0.0))
        for p in _records(session, "products")
        if p.get("is_active") not in (False, 0)
    ]
    rows.sort(key=lambda r: r["name"].lower())
    categories = [
        {"id": c["id"], "name": c.get("name") or ""}
        for c in sorted(_records(session, "categories"), key=lambda c: (int(_num(c.get("sort_order"))), c.get("name") or ""))
    ]
    return {"products": rows, "categories": categories}


def _customer_debts(session: Session, branch_id: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for d in _records(session, "customer_debts"):
        if (d.get("branch_id") or DEFAULT_BRANCH_ID) == branch_id:
            out[d.get("customer_id") or ""] = out.get(d.get("customer_id") or "", 0) + int(_num(d.get("amount")))
    return out


@router.get("/api/kassa/customers")
def customers(user: UserDep, session: SessionDep, branch_id: Annotated[str, Query()]) -> dict:
    _need(user, branch_id)
    debts = _customer_debts(session, branch_id)
    rows = [
        {"id": c["id"], "name": c.get("name") or "", "phone": c.get("phone") or "", "debt": debts.get(c["id"], 0)}
        for c in _records(session, "customers")
        if c.get("is_active") not in (False, 0)
    ]
    rows.sort(key=lambda r: (-r["debt"], r["name"].lower()))
    return {"customers": rows}


class CustomerBody(BaseModel):
    branch_id: str
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(default="", max_length=40)


@router.post("/api/kassa/customers")
def add_customer(body: CustomerBody, user: UserDep, session: SessionDep) -> dict:
    _need(user, body.branch_id)
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Mijoz ismini kiriting")
    cid = _new_id()
    now = sync.now_ms()
    with _LOCK:
        _write(session, [
            ("customers", {"id": cid, "name": name, "phone": body.phone.strip(), "address": "", "note": "",
                           "is_active": 1, **_base(now)}),
            _audit(user, "customer_saved", name, branch_id="", ref_id=cid),
        ])
    return {"id": cid, "name": name, "phone": body.phone.strip(), "debt": 0}


# ---------------------------------------------------------------------------
#  Savdo
# ---------------------------------------------------------------------------


class SaleLine(BaseModel):
    product_id: str
    qty: float = Field(gt=0, le=1_000_000)


class SaleBody(BaseModel):
    branch_id: str
    lines: list[SaleLine] = Field(min_length=1, max_length=500)
    discount_type: str = "none"  # none | percent | amount
    discount_value: float = Field(default=0, ge=0)
    paid_cash: int = Field(default=0, ge=0)
    paid_card: int = Field(default=0, ge=0)
    paid_transfer: int = Field(default=0, ge=0)
    debt: int = Field(default=0, ge=0)
    customer_id: str = ""
    note: str = Field(default="", max_length=500)


def _payment_type(b: SaleBody) -> str:
    if b.debt > 0:
        return "debt"
    parts = sum(1 for x in (b.paid_cash, b.paid_card, b.paid_transfer) if x > 0)
    if parts > 1:
        return "mixed"
    if b.paid_card > 0:
        return "card"
    if b.paid_transfer > 0:
        return "transfer"
    return "cash"


def _discount(subtotal: int, kind: str, value: float) -> int:
    """Ilovadagi CartState.discountAmount bilan bir xil."""
    if subtotal <= 0 or kind not in ("percent", "amount"):
        return 0
    raw = subtotal * value / 100 if kind == "percent" else value
    return max(0, min(_round(raw), subtotal))


def _allocate(discount: int, grosses: list[int]) -> list[int]:
    """Chek chegirmasini qatorlarga proporsional taqsimlash (CartState.allocateDiscount)."""
    sub = sum(grosses)
    if discount == 0 or sub == 0:
        return [0] * len(grosses)
    out: list[int] = []
    used = 0
    for i, g in enumerate(grosses):
        if i == len(grosses) - 1:
            out.append(discount - used)
        else:
            part = math.floor(discount * g / sub)
            out.append(part)
            used += part
    return out


@router.post("/api/kassa/sale")
def sale(body: SaleBody, user: UserDep, session: SessionDep) -> dict:
    role = _need(user, body.branch_id, session=session)
    lines = [(_product(session, ln.product_id), ln.qty) for ln in body.lines]
    grosses = [_round(q * int(_num(p.get("sale_price")))) for p, q in lines]
    subtotal = sum(grosses)
    discount = _discount(subtotal, body.discount_type, body.discount_value)
    if subtotal > 0 and discount * 100 / subtotal > CASHIER_MAX_DISCOUNT + 0.0001 and role != "admin":
        raise HTTPException(status_code=403, detail="20% dan yuqori chegirmani faqat Admin bera oladi")
    total = subtotal - discount
    if body.paid_card + body.paid_transfer > total:
        raise HTTPException(status_code=422, detail="Karta/o'tkazma summasi chek summasidan oshmasligi kerak")
    if body.debt > total:
        raise HTTPException(status_code=422, detail="Qarz summasi noto'g'ri")
    customer: dict | None = None
    if body.debt > 0:
        rec = session.get(SyncRecord, ("customers", body.customer_id)) if body.customer_id else None
        if rec is None or rec.deleted:
            raise HTTPException(status_code=422, detail="Nasiya uchun mijozni tanlang")
        customer = rec.data
    covered = body.paid_cash + body.paid_card + body.paid_transfer + body.debt
    if covered < total:
        raise HTTPException(status_code=422, detail="To'lov yetarli emas")
    change = covered - total
    if change > body.paid_cash:
        raise HTTPException(status_code=422, detail="Qaytim naqd summadan oshib ketdi")

    discounts = _allocate(discount, grosses)
    sale_id = _new_id()
    with _LOCK:
        now = sync.now_ms()
        receipt_no = _next_receipt(session)
        sale_row = {
            "id": sale_id, "receipt_no": receipt_no, "cashier_id": user.id, "cashier_name": user.name,
            "subtotal": subtotal, "discount_type": body.discount_type if discount else "none",
            "discount_value": body.discount_value if discount else 0, "discount_amount": discount,
            "discount_approved_by": None, "total": total, "payment_type": _payment_type(body),
            "paid_cash": body.paid_cash, "paid_card": body.paid_card, "paid_transfer": body.paid_transfer,
            "change_amount": change, "item_count": sum(q for _, q in lines),
            "cost_total": sum(_round(q * int(_num(p.get("purchase_price")))) for p, q in lines),
            "status": "completed", "refunded_at": None, "refunded_by": None, "note": body.note.strip(),
            "branch_id": body.branch_id, "debt_amount": body.debt,
            "customer_id": customer["id"] if customer else "", "customer_name": (customer or {}).get("name") or "",
            **_base(now),
        }
        records: list[tuple[str, dict]] = [("sales", sale_row)]
        items = []
        for i, ((p, q), gross, disc) in enumerate(zip(lines, grosses, discounts)):
            item = {
                "id": _new_id(), "sale_id": sale_id, "product_id": p["id"],
                "product_name": p.get("short_name") or p.get("name") or "", "barcode": p.get("barcode") or "",
                "unit": p.get("unit") or "dona", "qty": q, "price": int(_num(p.get("sale_price"))),
                "purchase_price": int(_num(p.get("purchase_price"))), "discount_amount": disc,
                "line_total": gross - disc, **_base(now), "created_at": now + i,
            }
            items.append(item)
            records.append(("sale_items", item))
            records.append(("stock_movements", {
                "id": _new_id(), "product_id": p["id"], "type": "sale", "qty": -q,
                "unit_cost": int(_num(p.get("purchase_price"))), "ref_id": sale_id, "note": receipt_no,
                "user_id": user.id, "user_name": user.name, "branch_id": body.branch_id, **_base(now),
            }))
        if customer:
            records.append(("customer_debts", {
                "id": _new_id(), "customer_id": customer["id"], "kind": "sale", "amount": body.debt,
                "sale_id": sale_id, "method": "", "note": receipt_no, "user_id": user.id, "user_name": user.name,
                "branch_id": body.branch_id, **_base(now),
            }))
        _write(session, records)
    return _sale_out(sale_row, items)


def _sale_out(s: dict, items: list[dict]) -> dict:
    return {
        "id": s["id"],
        "receipt_no": s.get("receipt_no") or "",
        "created_at": int(_num(s.get("created_at"))),
        "cashier": s.get("cashier_name") or "",
        "branch_id": s.get("branch_id") or DEFAULT_BRANCH_ID,
        "subtotal": int(_num(s.get("subtotal"))),
        "discount": int(_num(s.get("discount_amount"))),
        "total": int(_num(s.get("total"))),
        "payment": s.get("payment_type") or "",
        "paid_cash": int(_num(s.get("paid_cash"))),
        "paid_card": int(_num(s.get("paid_card"))),
        "paid_transfer": int(_num(s.get("paid_transfer"))),
        "change": int(_num(s.get("change_amount"))),
        "debt": int(_num(s.get("debt_amount"))),
        "customer": s.get("customer_name") or "",
        "status": s.get("status") or "",
        "items": [
            {
                "name": it.get("product_name") or "",
                "qty": _num(it.get("qty")),
                "unit": it.get("unit") or "",
                "price": int(_num(it.get("price"))),
                "discount": int(_num(it.get("discount_amount"))),
                "total": int(_num(it.get("line_total"))),
            }
            for it in sorted(items, key=lambda it: int(_num(it.get("created_at"))))
        ],
    }


@router.get("/api/kassa/sales")
def sales(user: UserDep, session: SessionDep, branch_id: Annotated[str, Query()],
          date: Annotated[str | None, Query(description="YYYY-MM-DD")] = None) -> dict:
    _need(user, branch_id)
    start, end = _range(date, date)
    rows = [
        s for s in _records(session, "sales", *_in_period(start, end))
        if (s.get("branch_id") or DEFAULT_BRANCH_ID) == branch_id
    ]
    rows.sort(key=lambda s: -int(_num(s.get("created_at"))))
    rows = rows[:500]
    items: dict[str, list[dict]] = {}
    for it in _by_ref(session, "sale_items", {s["id"] for s in rows}):
        items.setdefault(it.get("sale_id") or "", []).append(it)
    return {"sales": [_sale_out(s, items.get(s["id"], [])) for s in rows]}


class RefundBody(BaseModel):
    sale_id: str
    reason: str = Field(default="", max_length=300)


@router.post("/api/kassa/refund")
def refund(body: RefundBody, user: UserDep, session: SessionDep) -> dict:
    rec = session.get(SyncRecord, ("sales", body.sale_id))
    if rec is None or rec.deleted:
        raise HTTPException(status_code=404, detail="Chek topilmadi")
    s = dict(rec.data)
    branch_id = s.get("branch_id") or DEFAULT_BRANCH_ID
    _need(user, branch_id, "admin")
    if s.get("status") == "refunded":
        raise HTTPException(status_code=409, detail="Bu chek allaqachon qaytarilgan")
    items = _by_ref(session, "sale_items", {s["id"]})
    reason = body.reason.strip()
    with _LOCK:
        now = sync.now_ms()
        s.update(status="refunded", refunded_at=now, refunded_by=user.name, updated_at=now,
                 version=int(_num(s.get("version"))) + 1, device_id=DEVICE_ID)
        records: list[tuple[str, dict]] = [("sales", s)]
        note = f"{s.get('receipt_no')} {'— ' + reason if reason else ''}"
        for it in items:
            records.append(("stock_movements", {
                "id": _new_id(), "product_id": it.get("product_id"), "type": "customer_return",
                "qty": _num(it.get("qty")), "unit_cost": int(_num(it.get("purchase_price"))), "ref_id": s["id"],
                "note": note, "user_id": user.id, "user_name": user.name, "branch_id": branch_id, **_base(now),
            }))
        if int(_num(s.get("debt_amount"))) > 0 and s.get("customer_id"):
            records.append(("customer_debts", {
                "id": _new_id(), "customer_id": s["customer_id"], "kind": "refund",
                "amount": -int(_num(s.get("debt_amount"))), "sale_id": s["id"], "method": "",
                "note": s.get("receipt_no") or "", "user_id": user.id, "user_name": user.name,
                "branch_id": branch_id, **_base(now),
            }))
        records.append(_audit(user, "refund", f"{s.get('receipt_no')}: {int(_num(s.get('total')))} so'm. {reason}",
                              branch_id=branch_id))
        _write(session, records)
    return _sale_out(s, items)


class DebtPaymentBody(BaseModel):
    branch_id: str
    customer_id: str
    amount: int = Field(gt=0)
    method: str = "cash"
    note: str = Field(default="", max_length=300)


@router.post("/api/kassa/customer_payment")
def customer_payment(body: DebtPaymentBody, user: UserDep, session: SessionDep) -> dict:
    _need(user, body.branch_id)
    rec = session.get(SyncRecord, ("customers", body.customer_id))
    if rec is None or rec.deleted:
        raise HTTPException(status_code=404, detail="Mijoz topilmadi")
    with _LOCK:
        now = sync.now_ms()
        _write(session, [
            ("customer_debts", {
                "id": _new_id(), "customer_id": body.customer_id, "kind": "payment", "amount": -body.amount,
                "sale_id": "", "method": body.method if body.method in ("cash", "card", "transfer") else "cash",
                "note": body.note.strip(), "user_id": user.id, "user_name": user.name, "branch_id": body.branch_id,
                **_base(now),
            }),
            _audit(user, "customer_payment", f"{rec.data.get('name') or ''}: {_money(body.amount)}",
                   branch_id=body.branch_id, ref_id=body.customer_id),
        ])
    return {"debt": _customer_debts(session, body.branch_id).get(body.customer_id, 0)}


# ---------------------------------------------------------------------------
#  Ombor: kirim va tovarlar
# ---------------------------------------------------------------------------


class StockLine(BaseModel):
    product_id: str
    qty: float = Field(gt=0, le=1_000_000)
    unit_cost: int = Field(default=0, ge=0)


class StockInBody(BaseModel):
    branch_id: str
    lines: list[StockLine] = Field(min_length=1, max_length=500)
    note: str = Field(default="", max_length=300)


@router.post("/api/kassa/stock_in")
def stock_in(body: StockInBody, user: UserDep, session: SessionDep) -> dict:
    _need(user, body.branch_id, "admin", "storekeeper")
    with _LOCK:
        now = sync.now_ms()
        records: list[tuple[str, dict]] = []
        for ln in body.lines:
            p = _product(session, ln.product_id)
            cost = ln.unit_cost or int(_num(p.get("purchase_price")))
            records.append(("stock_movements", {
                "id": _new_id(), "product_id": p["id"], "type": "receipt", "qty": ln.qty, "unit_cost": cost,
                "ref_id": None, "note": body.note.strip(), "user_id": user.id, "user_name": user.name,
                "branch_id": body.branch_id, **_base(now),
            }))
            if ln.unit_cost and ln.unit_cost != int(_num(p.get("purchase_price"))):
                old = int(_num(p.get("purchase_price")))
                p.update(purchase_price=ln.unit_cost, updated_at=now, version=int(_num(p.get("version"))) + 1,
                         device_id=DEVICE_ID)
                records.append(("products", p))
                records.append(_audit(user, "price_changed", f"{p.get('name')}: kirim narxi {old} → {ln.unit_cost}",
                                      branch_id="", ref_id=p["id"]))
        _write(session, records)
    ids = [ln.product_id for ln in body.lines]
    qty = stock_qty(session, {body.branch_id}, ids)
    return {"qty": {pid: round(qty.get(pid, {}).get(body.branch_id, 0.0), 3) for pid in ids}}


class ProductBody(BaseModel):
    branch_id: str
    id: str | None = None
    name: str = Field(min_length=1, max_length=200)
    barcode: str = Field(default="", max_length=64)
    sku: str = Field(default="", max_length=64)
    unit: str = Field(default="dona", max_length=20)
    category_id: str | None = None
    is_weighted: bool = False
    sale_price: int = Field(default=0, ge=0)
    purchase_price: int = Field(default=0, ge=0)
    min_stock: float = Field(default=0, ge=0)


_PRODUCT_FIELDS = {
    "name": "nomi", "barcode": "shtrix-kod", "sku": "artikul", "unit": "birlik", "category_id": "kategoriya",
    "is_weighted": "tarozi", "min_stock": "min. qoldiq",
}


@router.post("/api/kassa/product")
def save_product(body: ProductBody, user: UserDep, session: SessionDep) -> dict:
    _need(user, body.branch_id, "admin", "storekeeper")
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=422, detail="Tovar nomini kiriting")
    barcode = body.barcode.strip()
    if barcode:
        for p in _records(session, "products"):
            if p["id"] != body.id and barcode in (p.get("barcode"), p.get("barcode2")):
                raise HTTPException(status_code=409, detail=f"Bu shtrix-kod boshqa tovarda bor: {p.get('name')}")
    values = {
        "name": name, "barcode": barcode, "sku": body.sku.strip(), "unit": body.unit.strip() or "dona",
        "category_id": body.category_id or None, "is_weighted": 1 if body.is_weighted else 0,
        "sale_price": body.sale_price, "purchase_price": body.purchase_price, "min_stock": body.min_stock,
    }
    with _LOCK:
        now = sync.now_ms()
        if body.id:
            p = _product(session, body.id)
            prices = [
                f"{label} {int(_num(p.get(k)))} → {values[k]}"
                for k, label in (("sale_price", "sotuv"), ("purchase_price", "kirim"))
                if int(_num(p.get(k))) != values[k]
            ]
            changed = [label for k, label in _PRODUCT_FIELDS.items() if (p.get(k) or None) != (values[k] or None)]
            p.update(values, updated_at=now, version=int(_num(p.get("version"))) + 1, device_id=DEVICE_ID)
            records: list[tuple[str, dict]] = [("products", p)]
            if prices:
                records.append(_audit(user, "price_changed", f"{name}: {', '.join(prices)}", branch_id="", ref_id=p["id"]))
            if changed:
                records.append(_audit(user, "product_updated", f"{name}: {', '.join(changed)}", branch_id="", ref_id=p["id"]))
        else:
            p = {
                "id": _new_id(), **values, "short_name": "", "description": "", "brand": "", "manufacturer": "",
                "country": "", "supplier": "", "mxik_code": "", "package_code": "", "vat_percent": 12,
                "pack_qty": 1, "wholesale_price": 0, "max_stock": 0, "location": "", "color": "", "size": "",
                "material": "", "weight_kg": 0, "volume_l": 0, "warranty_months": 0, "season_tags": "",
                "is_active": 1, "image_path": "", "notes": "", "barcode2": "", **_base(now),
            }
            records = [("products", p), _audit(user, "product_created", name, branch_id="", ref_id=p["id"])]
        _write(session, records)
    qty = stock_qty(session, {body.branch_id}, [p["id"]])
    return _product_row(p, qty.get(p["id"], {}).get(body.branch_id, 0.0))


# ---------------------------------------------------------------------------
#  Rasm va sahifa
# ---------------------------------------------------------------------------


@router.get("/api/kassa/image/{name}", include_in_schema=False)
def image(name: str, user: UserDep) -> FileResponse:
    from .main import _image_path  # aylanma importdan qochish

    path = _image_path(name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Rasm topilmadi")
    return FileResponse(path, headers={"Cache-Control": "max-age=86400"})


@router.get("/kassa", include_in_schema=False)
def page() -> FileResponse:
    return FileResponse(PAGE, media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-cache"})
