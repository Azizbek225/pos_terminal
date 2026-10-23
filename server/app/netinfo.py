"""Kompyuterning tarmoq manzillari (PosServer oynasi va QR ulash sahifasi uchun)."""

from __future__ import annotations

import socket


def local_ips() -> list[str]:
    """Kompyuterning barcha lokal IPv4 manzillari (asosiysi birinchi)."""
    ips: list[str] = []
    try:
        # Hech narsa yubormaydi: faqat tarmoqqa chiqadigan interfeys manzilini aniqlaydi.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            ips.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    # Wi-Fi odatda 192.168.x.x — shunday manzillar oldinda tursin.
    ips.sort(key=lambda ip: 0 if ip.startswith("192.168.") else 1)
    return ips or ["127.0.0.1"]
