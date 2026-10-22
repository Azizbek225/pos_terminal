"""Web hisobot paneli: egasi brauzerda (http://<server>:8000/) savdo, qoldiq,
qarzlar va o'zgarishlarni ko'radi. Faqat o'qish — kassa ilovada qoladi.

Kirish ilovadagi xodimlar bilan (sinxronlangan `users`, PBKDF2 hash) yoki
login "admin" + PosServer oynasidagi API kalit bilan (xodimlar hali
sinxronlanmagan bo'lsa). Ruxsat: bosh admin — barcha filiallar, filial
admini — faqat o'z filiallari.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

from fastapi import APIRouter, Cookie, Depends, HTTPException, Query, Response
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import get_session
from .models import Device, SyncRecord

# Ilovadagi kDefaultBranchId bilan bir xil (filialdan oldingi yozuvlar).
DEFAULT_BRANCH_ID = "00000000-0000-4000-8000-200000000001"
COOKIE = "pos_web"
TOKEN_TTL = 7 * 24 * 3600
KEY_USER = "__api_key__"
PAGE = Path(__file__).resolve().parent / "static" / "panel.html"

router = APIRouter()
SessionDep = Annotated[Session, Depends(get_session)]


# ---------------------------------------------------------------------------
#  Kirish
# ---------------------------------------------------------------------------


def verify_password(password: str, salt: str, expected: str) -> bool:
    """Ilovadagi PasswordHasher bilan bir xil: PBKDF2-HMAC-SHA256, 20000, 32 bayt."""
    key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 20000, 32)
    return hmac.compare_digest(base64.urlsafe_b64encode(key).decode(), expected or "")


def _secret() -> bytes:
    return hashlib.sha256(b"pos-web:" + settings.api_key.encode()).digest()


def make_token(user_id: str, now: float | None = None) -> str:
    payload = base64.urlsafe_b64encode(f"{user_id}|{int((now or time.time()) + TOKEN_TTL)}".encode()).decode()
    sig = hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def read_token(token: str | None) -> str | None:
    if not token or "." not in token:
        return None
    payload, sig = token.rsplit(".", 1)
    if not hmac.compare_digest(hmac.new(_secret(), payload.encode(), hashlib.sha256).hexdigest(), sig):
        return None
    try:
        user_id, exp = base64.urlsafe_b64decode(payload.encode()).decode().rsplit("|", 1)
    except (ValueError, UnicodeDecodeError):
        return None
    return user_id if int(exp) > time.time() else None


def _records(session: Session, entity: str) -> list[dict]:
    rows = session.execute(
        select(SyncRecord.data).where(SyncRecord.entity == entity, SyncRecord.deleted.is_(False))
    ).scalars()
    return [d for d in rows if not d.get("is_deleted")]


def _branch_roles(user: dict) -> dict[str, str]:
    try:
        m = json.loads(user.get("branch_roles") or "{}")
        return {str(k): str(v) for k, v in m.items()} if isinstance(m, dict) else {}
    except ValueError:
        return {}


class WebUser(BaseModel):
    id: str
    name: str
    # None — barcha filiallar (bosh admin).
    branches: set[str] | None


def access_of(user: dict) -> set[str] | None | bool:
    """Panelga ruxsat: None — hamma filial, set — shu filiallar, False — yo'q."""
    if user.get("is_active") in (False, 0):
        return False
    roles = _branch_roles(user)
    if not roles:
        return None if user.get("role") == "admin" else False
    allowed = {b for b, r in roles.items() if r == "admin"}
    return allowed or False


def _find_user(session: Session, user_id: str) -> dict | None:
    rec = session.get(SyncRecord, ("users", user_id))
    return rec.data if rec and not rec.deleted and not rec.data.get("is_deleted") else None


def current_user(session: SessionDep, pos_web: Annotated[str | None, Cookie()] = None) -> WebUser:
    uid = read_token(pos_web)
    if uid == KEY_USER:
        return WebUser(id=uid, name="Admin", branches=None)
    user = _find_user(session, uid) if uid else None
    access = access_of(user) if user else False
    if user is None or access is False:
        raise HTTPException(status_code=401, detail="Kirish kerak")
    return WebUser(id=uid, name=user.get("full_name") or user.get("username") or "", branches=access)


UserDep = Annotated[WebUser, Depends(current_user)]


class LoginBody(BaseModel):
    username: str
    password: str


@router.post("/api/web/login")
def login(body: LoginBody, session: SessionDep, response: Response) -> dict:
    uname = body.username.strip().lower()
    uid: str | None = None
    for u in _records(session, "users"):
        if str(u.get("username") or "").lower() == uname:
            if verify_password(body.password, u.get("salt") or "", u.get("password_hash") or ""):
                if access_of(u) is False:
                    raise HTTPException(status_code=403, detail="Panel faqat admin uchun")
                uid = u["id"]
            break
    if uid is None and uname == "admin" and hmac.compare_digest(body.password, settings.api_key):
        uid = KEY_USER
    if uid is None:
        raise HTTPException(status_code=401, detail="Login yoki parol noto'g'ri")
    response.set_cookie(COOKIE, make_token(uid), max_age=TOKEN_TTL, httponly=True, samesite="lax")
    return {"ok": True}


@router.post("/api/web/logout")
def logout(response: Response) -> dict:
    response.delete_cookie(COOKIE)
    return {"ok": True}


# ---------------------------------------------------------------------------
#  Yordamchilar
# ---------------------------------------------------------------------------


def _range(date_from: str | None, date_to: str | None) -> tuple[int, int]:
    try:
        today = datetime.now().strftime("%Y-%m-%d")
        start = datetime.strptime(date_from or today, "%Y-%m-%d")
        end = datetime.strptime(date_to or date_from or today, "%Y-%m-%d")
    except ValueError as e:
        raise HTTPException(status_code=422, detail="Sana formati: YYYY-MM-DD") from e
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000) + 86_400_000


def _branches_filter(user: WebUser, branch_id: str | None) -> set[str] | None:
    """So'rov uchun filiallar: None — hammasi."""
    if branch_id:
        if user.branches is not None and branch_id not in user.branches:
            raise HTTPException(status_code=403, detail="Bu filialga ruxsat yo'q")
        return {branch_id}
    return user.branches


def _in(d: dict, branches: set[str] | None) -> bool:
    return branches is None or (d.get("branch_id") or DEFAULT_BRANCH_ID) in branches


def _day(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d")


def _num(v: Any) -> float:
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


DateFrom = Annotated[str | None, Query(description="YYYY-MM-DD")]
DateTo = Annotated[str | None, Query(description="YYYY-MM-DD (shu kun ham kiradi)")]
BranchQ = Annotated[str | None, Query(description="Filial (bo'sh — hammasi)")]


# ---------------------------------------------------------------------------
#  Ma'lumotlar
# ---------------------------------------------------------------------------


@router.get("/api/web/me")
def me(user: UserDep, session: SessionDep) -> dict:
    branches = [
        {"id": b["id"], "name": b.get("name") or ""}
        for b in sorted(_records(session, "branches"), key=lambda b: (int(_num(b.get("sort_order"))), b.get("name") or ""))
        if user.branches is None or b["id"] in user.branches
    ]
    if not branches:
        branches = [{"id": DEFAULT_BRANCH_ID, "name": "Asosiy filial"}]
    return {"name": user.name, "owner": user.branches is None, "branches": branches}


@router.get("/api/web/overview")
def overview(user: UserDep, session: SessionDep, date_from: DateFrom = None, date_to: DateTo = None,
             branch_id: BranchQ = None) -> dict:
    start, end = _range(date_from, date_to)
    branches = _branches_filter(user, branch_id)
    days: dict[str, dict[str, int]] = defaultdict(lambda: {"total": 0, "count": 0, "profit": 0})
    cashiers: dict[str, dict[str, int]] = defaultdict(lambda: {"total": 0, "count": 0})
    by_branch: dict[str, int] = defaultdict(int)
    pay = {"cash": 0, "card": 0, "transfer": 0, "debt": 0}
    total = count = profit = discount = refunds = refund_sum = 0
    sale_ids: set[str] = set()
    for s in _records(session, "sales"):
        created = int(_num(s.get("created_at")))
        if not (start <= created < end) or not _in(s, branches):
            continue
        if s.get("status") == "refunded":
            refunds += 1
            refund_sum += int(_num(s.get("total")))
            continue
        if s.get("status") != "completed":
            continue
        t = int(_num(s.get("total")))
        p = t - int(_num(s.get("cost_total")))
        sale_ids.add(s["id"])
        total += t
        count += 1
        profit += p
        discount += int(_num(s.get("discount_amount")))
        day = days[_day(created)]
        day["total"] += t
        day["count"] += 1
        day["profit"] += p
        c = cashiers[str(s.get("cashier_name") or "—")]
        c["total"] += t
        c["count"] += 1
        by_branch[s.get("branch_id") or DEFAULT_BRANCH_ID] += t
        pay["cash"] += int(_num(s.get("paid_cash")) - _num(s.get("change_amount")))
        pay["card"] += int(_num(s.get("paid_card")))
        pay["transfer"] += int(_num(s.get("paid_transfer")))
        pay["debt"] += int(_num(s.get("debt_amount")))

    products: dict[str, dict[str, Any]] = {}
    for it in _records(session, "sale_items"):
        if it.get("sale_id") not in sale_ids:
            continue
        key = it.get("product_id") or it.get("product_name") or ""
        row = products.setdefault(key, {"name": it.get("product_name") or "", "unit": it.get("unit") or "", "qty": 0.0, "total": 0})
        row["qty"] += _num(it.get("qty"))
        row["total"] += int(_num(it.get("line_total")))
    top = sorted(products.values(), key=lambda r: -r["total"])[:20]

    return {
        "total": total,
        "count": count,
        "average": round(total / count) if count else 0,
        "profit": profit,
        "discount": discount,
        "refunds": refunds,
        "refund_sum": refund_sum,
        "payments": pay,
        "days": [{"date": k, **v} for k, v in sorted(days.items())],
        "cashiers": sorted(({"name": k, **v} for k, v in cashiers.items()), key=lambda r: -r["total"]),
        "by_branch": dict(by_branch),
        "top_products": top,
    }


@router.get("/api/web/sales")
def sales(user: UserDep, session: SessionDep, date_from: DateFrom = None, date_to: DateTo = None,
          branch_id: BranchQ = None, limit: Annotated[int, Query(ge=1, le=2000)] = 300) -> dict:
    start, end = _range(date_from, date_to)
    branches = _branches_filter(user, branch_id)
    rows = [
        s for s in _records(session, "sales")
        if start <= int(_num(s.get("created_at"))) < end and _in(s, branches)
    ]
    rows.sort(key=lambda s: -int(_num(s.get("created_at"))))
    rows = rows[:limit]
    ids = {s["id"] for s in rows}
    items: dict[str, list[dict]] = defaultdict(list)
    for it in _records(session, "sale_items"):
        if it.get("sale_id") in ids:
            items[it["sale_id"]].append({
                "name": it.get("product_name") or "",
                "qty": _num(it.get("qty")),
                "unit": it.get("unit") or "",
                "price": int(_num(it.get("price"))),
                "total": int(_num(it.get("line_total"))),
            })
    return {
        "sales": [
            {
                "id": s["id"],
                "receipt_no": s.get("receipt_no") or "",
                "created_at": int(_num(s.get("created_at"))),
                "cashier": s.get("cashier_name") or "",
                "branch_id": s.get("branch_id") or DEFAULT_BRANCH_ID,
                "total": int(_num(s.get("total"))),
                "discount": int(_num(s.get("discount_amount"))),
                "payment": s.get("payment_type") or "",
                "debt": int(_num(s.get("debt_amount"))),
                "customer": s.get("customer_name") or "",
                "status": s.get("status") or "",
                "items": items.get(s["id"], []),
            }
            for s in rows
        ]
    }


@router.get("/api/web/stock")
def stock(user: UserDep, session: SessionDep, branch_id: BranchQ = None) -> dict:
    """Qoldiq ombor harakatlari yig'indisidan (ilovadagi kabi), filial bo'yicha."""
    branches = _branches_filter(user, branch_id)
    qty: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    for m in _records(session, "stock_movements"):
        if _in(m, branches):
            qty[m.get("product_id") or ""][m.get("branch_id") or DEFAULT_BRANCH_ID] += _num(m.get("qty"))
    categories = {c["id"]: c.get("name") or "" for c in _records(session, "categories")}
    out = []
    for p in _records(session, "products"):
        if p.get("is_active") in (False, 0):
            continue
        per = {b: round(q, 3) for b, q in qty.get(p["id"], {}).items()}
        total = round(sum(per.values()), 3)
        min_stock = _num(p.get("min_stock"))
        out.append({
            "id": p["id"],
            "name": p.get("name") or "",
            "barcode": p.get("barcode") or "",
            "sku": p.get("sku") or "",
            "category": categories.get(p.get("category_id") or "", ""),
            "unit": p.get("unit") or "",
            "sale_price": int(_num(p.get("sale_price"))),
            "purchase_price": int(_num(p.get("purchase_price"))),
            "min_stock": min_stock,
            "qty": total,
            "by_branch": per,
            "low": min_stock > 0 and total <= min_stock,
        })
    out.sort(key=lambda r: r["name"].lower())
    value = sum(max(r["qty"], 0) * r["purchase_price"] for r in out)
    return {"products": out, "stock_value": round(value), "low_count": sum(1 for r in out if r["low"])}


@router.get("/api/web/debts")
def debts(user: UserDep, session: SessionDep, branch_id: BranchQ = None) -> dict:
    branches = _branches_filter(user, branch_id)
    sup: dict[str, dict[str, int]] = defaultdict(lambda: {"purchased": 0, "paid": 0})
    for p in _records(session, "supplier_purchases"):
        if _in(p, branches):
            sup[p.get("supplier_id") or ""]["purchased"] += int(_num(p.get("total")))
    for p in _records(session, "supplier_payments"):
        if _in(p, branches):
            sup[p.get("supplier_id") or ""]["paid"] += int(_num(p.get("amount")))
    suppliers = []
    for s in _records(session, "suppliers"):
        b = sup.get(s["id"], {"purchased": 0, "paid": 0})
        suppliers.append({"name": s.get("name") or "", "phone": s.get("phone") or "",
                          **b, "debt": b["purchased"] - b["paid"]})
    suppliers.sort(key=lambda r: (-r["debt"], r["name"].lower()))

    cus: dict[str, dict[str, int]] = defaultdict(lambda: {"debt": 0, "last_at": 0})
    for d in _records(session, "customer_debts"):
        if _in(d, branches):
            c = cus[d.get("customer_id") or ""]
            c["debt"] += int(_num(d.get("amount")))
            c["last_at"] = max(c["last_at"], int(_num(d.get("created_at"))))
    customers = []
    for c in _records(session, "customers"):
        b = cus.get(c["id"], {"debt": 0, "last_at": 0})
        customers.append({"name": c.get("name") or "", "phone": c.get("phone") or "", **b})
    customers.sort(key=lambda r: (-r["debt"], r["name"].lower()))
    return {
        "suppliers": suppliers,
        "customers": customers,
        "supplier_debt": sum(r["debt"] for r in suppliers if r["debt"] > 0),
        "supplier_advance": -sum(r["debt"] for r in suppliers if r["debt"] < 0),
        "customer_debt": sum(r["debt"] for r in customers if r["debt"] > 0),
    }


@router.get("/api/web/activity")
def activity(user: UserDep, session: SessionDep, date_from: DateFrom = None, date_to: DateTo = None,
             branch_id: BranchQ = None) -> dict:
    """O'zgarishlar jurnali (audit) va qurilmalarning oxirgi ulanishi."""
    start, end = _range(date_from, date_to)
    branches = _branches_filter(user, branch_id)
    log = [
        {
            "created_at": int(_num(a.get("created_at"))),
            "user": a.get("user_name") or "",
            "action": a.get("action") or "",
            "details": a.get("details") or "",
            # Bo'sh filial — umumiy yozuv (xodim, filial sozlamalari).
            "branch_id": a.get("branch_id") or "",
        }
        for a in _records(session, "audit_log")
        if start <= int(_num(a.get("created_at"))) < end
        and (branches is None or (a.get("branch_id") or "") in branches or (user.branches is None and not a.get("branch_id")))
    ]
    log.sort(key=lambda r: -r["created_at"])
    devices = [
        {"id": d.id, "last_push_at": d.last_push_at, "last_pull_at": d.last_pull_at, "pushed_count": d.pushed_count}
        for d in session.execute(select(Device)).scalars()
    ]
    devices.sort(key=lambda d: -max(d["last_push_at"] or 0, d["last_pull_at"] or 0))
    return {"log": log[:1000], "devices": devices if user.branches is None else []}


# ---------------------------------------------------------------------------
#  Sahifa
# ---------------------------------------------------------------------------


@router.get("/", include_in_schema=False)
def root() -> RedirectResponse:
    return RedirectResponse("/panel")


@router.get("/panel", include_in_schema=False)
def panel() -> FileResponse:
    return FileResponse(PAGE, media_type="text/html; charset=utf-8", headers={"Cache-Control": "no-cache"})
