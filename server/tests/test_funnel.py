"""Internetdan ochish (Tailscale Funnel) testlari — soxta tailscale CLI bilan."""

import json
import sys
import time
from pathlib import Path

import pytest

from .test_sync import client, fresh_db  # noqa: F401  (birinchi: muhit o'zgaruvchilari)
from .test_web import login, seed

from app import funnel, web  # noqa: E402

FAKE = Path(__file__).with_name("fake_tailscale.py")


@pytest.fixture
def ts(monkeypatch, tmp_path):
    if sys.platform == "win32":
        pytest.skip("soxta CLI shebang orqali ishlaydi")
    state = tmp_path / "ts.json"
    state.write_text("{}", encoding="utf-8")
    monkeypatch.setenv("POS_TAILSCALE", str(FAKE))
    monkeypatch.setenv("FAKE_TS_STATE", str(state))

    def set_(**kw):
        st = json.loads(state.read_text(encoding="utf-8"))
        state.write_text(json.dumps({**st, **kw}), encoding="utf-8")

    return set_


def wait_ready(client):
    for _ in range(100):
        st = client.get("/api/funnel").json()
        if not st["pending"]:
            return st
        time.sleep(0.05)
    raise AssertionError(st)


def test_not_installed(client, monkeypatch):
    monkeypatch.setattr(funnel, "binary", lambda: None)
    seed(client)
    assert client.get("/api/funnel").status_code == 401
    login(client)
    st = client.get("/api/funnel").json()
    assert st["state"] == "not_installed" and st["download"].startswith("https://tailscale.com")
    assert funnel.public_url(8000) is None


def test_login_then_funnel_on_and_off(client, ts):
    seed(client)
    login(client, "filial")
    assert client.get("/api/funnel").status_code == 403  # filial admini emas, faqat bosh admin
    client.cookies.clear()
    login(client)
    assert client.get("/api/funnel").json()["state"] == "need_login"

    r = client.post("/api/funnel", json={"on": True}).json()
    assert r["pending"] == {"action": "login", "url": "https://login.tailscale.com/a/abc123"}
    ts(login=True)
    assert wait_ready(client)["state"] == "off"

    # Tailnet'da Funnel hali yoqilmagan: bir martalik ruxsat havolasi.
    r = client.post("/api/funnel", json={"on": True}).json()
    assert r["pending"]["url"] == "https://login.tailscale.com/f/funnel?node=n1"
    ts(approved=True)
    st = wait_ready(client)
    assert st["state"] == "on" and st["url"] == "https://kassa.tail1.ts.net" and "<svg" in st["qr"]
    assert "https://kassa.tail1.ts.net" in json.loads(web.connect_payload(8000))["urls"]

    r = client.post("/api/funnel", json={"on": False}).json()
    assert r["ok"] and r["status"]["state"] == "off"
    # Ruxsat berilgan — keyingi yoqish darhol.
    r = client.post("/api/funnel", json={"on": True}).json()
    assert r["ok"] and r["status"]["state"] == "on"


FWD = {"x-forwarded-for": "203.0.113.9", "tailscale-funnel-request": "?1"}


def test_internet_login_rules(client):
    # Xodimlar sinxronlanmagan: lokal tarmoqda admin123 ishlaydi, internetdan — yo'q.
    body = {"username": "admin", "password": "admin123"}
    assert client.post("/api/kassa/login", json=body).status_code == 200
    r = client.post("/api/kassa/login", json=body, headers=FWD)
    assert r.status_code == 401 and "Internet" in r.json()["detail"]
    assert client.post("/api/kassa/login", json={"username": "admin", "password": "test-key"}, headers=FWD).status_code == 200


def test_login_rate_limit(client):
    bad = {"username": "admin", "password": "xato"}
    for _ in range(web.LOGIN_TRIES):
        assert client.post("/api/web/login", json=bad, headers=FWD).status_code == 401
    assert client.post("/api/web/login", json={"username": "admin", "password": "test-key"}, headers=FWD).status_code == 429
    # Boshqa manzil bloklanmaydi.
    other = {**FWD, "x-forwarded-for": "198.51.100.1"}
    assert client.post("/api/web/login", json={"username": "admin", "password": "test-key"}, headers=other).status_code == 200


def test_forwarded_is_not_local():
    class R:
        headers = {"tailscale-funnel-request": "?1"}

    assert funnel.is_forwarded(R())
    R.headers = {}
    assert not funnel.is_forwarded(R())
