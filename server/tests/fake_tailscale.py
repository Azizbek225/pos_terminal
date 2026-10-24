#!/usr/bin/env python3
"""Testlar uchun soxta `tailscale` CLI. Holat FAKE_TS_STATE JSON faylida."""

import json
import os
import sys
import time

STATE = os.environ["FAKE_TS_STATE"]


def load():
    with open(STATE, encoding="utf-8") as f:
        return json.load(f)


def save(st):
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(st, f)


def wait_for(key):
    for _ in range(300):
        if load().get(key):
            return
        time.sleep(0.05)
    sys.exit(1)


args = sys.argv[1:]
st = load()
if args == ["status", "--json"]:
    if not st.get("login"):
        print(json.dumps({"BackendState": "NeedsLogin", "AuthURL": ""}))
    else:
        print(json.dumps({"BackendState": "Running", "Self": {"DNSName": "kassa.tail1.ts.net."}}))
elif args == ["login"]:
    print("To authenticate, visit:\n\n\thttps://login.tailscale.com/a/abc123\n", flush=True)
    wait_for("login")
elif args == ["funnel", "status", "--json"]:
    if st.get("funnel"):
        print(json.dumps({
            "TCP": {"443": {"HTTPS": True}},
            "Web": {"kassa.tail1.ts.net:443": {"Handlers": {"/": {"Proxy": f"http://127.0.0.1:{st['funnel']}"}}}},
            "AllowFunnel": {"kassa.tail1.ts.net:443": True},
        }))
    else:
        print("{}")
elif args[:3] == ["funnel", "--bg", "--yes"]:
    if not st.get("approved"):
        print("Funnel is not enabled on your tailnet.\nTo enable, visit:\n\n"
              "         https://login.tailscale.com/f/funnel?node=n1\n", flush=True)
        wait_for("approved")
    st = load()
    st["funnel"] = args[3]
    save(st)
    print("Available on the internet:\n\nhttps://kassa.tail1.ts.net/", flush=True)
elif args in (["funnel", "--https=443", "off"], ["funnel", "reset"]):
    st["funnel"] = None
    save(st)
else:
    print("unknown " + " ".join(args), file=sys.stderr)
    sys.exit(2)
