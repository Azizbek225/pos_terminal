"""Windows uchun bitta faylli server (PosServer.exe) ishga tushirgichi.

Docker va PostgreSQL kerak emas: baza (pos.db) va API kalit (api_kalit.txt)
exe yonidagi papkada saqlanadi. Ishga tushganda kompyuter IP manzili va
kalit ekranga chiqadi — ularni telefondagi Sozlamalar > Sinxronlash ga yozing.

    python run_server.py          # yoki PyInstaller bilan yig'ilgan PosServer.exe
    PosServer.exe --autostart-off # Windows bilan avtomatik ishga tushishni o'chirish

PosServer.exe birinchi ishga tushganda o'zini Windows avtomatik ishga
tushirishga qo'shadi (HKCU\\...\\Run, administrator kerak emas) va keyingi
safar kichraytirilgan oynada yonadi. Tarmoqda UDP orqali o'zini e'lon qiladi:
kompyuter IP si o'zgarsa, telefon serverni o'zi qayta topadi.
"""

from __future__ import annotations

import json
import os
import secrets
import socket
import subprocess
import sys
import threading
from pathlib import Path

PORT = int(os.environ.get("POS_PORT", "8000"))
DISCOVERY_PORT = int(os.environ.get("POS_DISCOVERY_PORT", "8765"))
DISCOVERY_MAGIC = b"POS_DISCOVER"
AUTOSTART_NAME = "PosServer"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def base_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def load_api_key(folder: Path) -> str:
    if os.environ.get("POS_API_KEY"):
        return os.environ["POS_API_KEY"]
    key_file = folder / "api_kalit.txt"
    if key_file.exists() and key_file.read_text(encoding="utf-8").strip():
        return key_file.read_text(encoding="utf-8").strip()
    key = secrets.token_hex(6)
    key_file.write_text(key, encoding="utf-8")
    return key


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


def open_firewall() -> None:
    if os.name != "nt":
        return
    rules = [
        ("POS Terminal Sync", "TCP", PORT),
        ("POS Terminal Discovery", "UDP", DISCOVERY_PORT),
    ]
    elevated: list[str] = []
    try:
        for name, proto, port in rules:
            exists = subprocess.run(
                ["netsh", "advfirewall", "firewall", "show", "rule", f"name={name}"],
                capture_output=True,
            ).returncode == 0
            if exists:
                continue
            argv = ["netsh", "advfirewall", "firewall", "add", "rule", f"name={name}", "dir=in", "action=allow",
                    f"protocol={proto}", f"localport={port}", "profile=any"]
            if subprocess.run(argv, capture_output=True).returncode != 0:
                elevated.append(
                    f'netsh advfirewall firewall add rule name="{name}" dir=in action=allow '
                    f"protocol={proto} localport={port} profile=any"
                )
        if elevated:
            # Administrator huquqi kerak: Windows bir marta "Ha" deb so'raydi.
            import ctypes

            ctypes.windll.shell32.ShellExecuteW(None, "runas", "cmd", "/c " + " & ".join(elevated), None, 0)
    except (OSError, AttributeError):
        pass


def set_autostart(enable: bool) -> bool:
    """Windows'ga kirganda PosServer.exe ni avtomatik ishga tushirish (faqat exe)."""
    if os.name != "nt" or not getattr(sys, "frozen", False):
        return False
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_READ | winreg.KEY_SET_VALUE) as key:
            if enable:
                cmd = f'"{sys.executable}" --minimized'
                try:
                    current = winreg.QueryValueEx(key, AUTOSTART_NAME)[0]
                except FileNotFoundError:
                    current = None
                # Exe boshqa papkaga ko'chirilsa yo'l yangilanadi.
                if current != cmd:
                    winreg.SetValueEx(key, AUTOSTART_NAME, 0, winreg.REG_SZ, cmd)
            else:
                try:
                    winreg.DeleteValue(key, AUTOSTART_NAME)
                except FileNotFoundError:
                    pass
        return True
    except OSError:
        return False


def minimize_console() -> None:
    if os.name != "nt":
        return
    try:
        import ctypes

        hwnd = ctypes.windll.kernel32.GetConsoleWindow()
        if hwnd:
            ctypes.windll.user32.ShowWindow(hwnd, 6)  # SW_MINIMIZE
    except (OSError, AttributeError):
        pass


def already_running(port: int = PORT) -> bool:
    """Shu portda server allaqachon ishlayaptimi (ikkinchi nusxa ochilmasin)."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def start_discovery(port: int = PORT, discovery_port: int = DISCOVERY_PORT) -> socket.socket | None:
    """Telefon tarmoqqa "POS_DISCOVER" deb so'rasa, server port bilan javob beradi.

    Shu tufayli kompyuter IP si o'zgarsa ham telefon serverni qayta topadi.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("", discovery_port))
    except OSError as e:
        print(f"  Ogohlantirish: avtomatik topish ishlamaydi ({e})", flush=True)
        return None
    reply = json.dumps({"app": "pos-sync", "port": port, "name": socket.gethostname()}).encode()

    def loop() -> None:
        while True:
            try:
                data, addr = sock.recvfrom(1024)
                if data.strip() == DISCOVERY_MAGIC:
                    sock.sendto(reply, addr)
            except OSError:
                # Windows UDP da ConnectionResetError bo'lishi mumkin; yopilgan bo'lsa chiqamiz.
                if sock.fileno() == -1:
                    return

    threading.Thread(target=loop, name="pos-discovery", daemon=True).start()
    return sock


def main() -> None:
    args = set(sys.argv[1:])
    if "--autostart-off" in args:
        ok = set_autostart(False)
        print("Avtomatik ishga tushish o'chirildi." if ok else "Faqat Windows'dagi PosServer.exe uchun.")
        return
    minimized = "--minimized" in args
    if minimized:
        minimize_console()
    if already_running():
        print(f"PosServer allaqachon ishlayapti (port {PORT}). Bu oynani yopishingiz mumkin.")
        if not minimized and sys.stdin and sys.stdin.isatty():
            input("Yopish uchun Enter bosing...")
        return

    folder = base_dir()
    os.chdir(folder)
    os.environ.setdefault("POS_DATABASE_URL", f"sqlite:///{(folder / 'pos.db').as_posix()}")
    os.environ["POS_API_KEY"] = load_api_key(folder)
    open_firewall()
    autostart = set_autostart(True)
    start_discovery()

    print("=" * 56)
    print("  POS Terminal - sinxronlash serveri ishlayapti")
    print("=" * 56)
    ips = local_ips()
    print(f"  Server manzili : http://{ips[0]}:{PORT}")
    for ip in ips[1:]:
        print(f"  (yoki          : http://{ip}:{PORT})")
    print(f"  API kalit      : {os.environ['POS_API_KEY']}")
    print()
    print("  Shu ikkalasini har bir qurilmada yozing:")
    print("  Sozlamalar > Sinxronlash")
    print()
    print(f"  Hisobot paneli : brauzerda http://{ips[0]}:{PORT}")
    print("  (ilovadagi admin login/paroli yoki admin + API kalit)")
    print()
    print("  Bu oynani yopmang (yopsangiz sinxronlash to'xtaydi).")
    if autostart:
        print("  Windows yonganda server o'zi ishga tushadi.")
        print("  (O'chirish: PosServer.exe --autostart-off)")
    print("  IP o'zgarsa telefon serverni o'zi qayta topadi.")
    print("  Pastda har bir qurilma ulanganda qator chiqadi:")
    print("  push = yubordi, pull = oldi. Telefon IP si ko'rinmasa,")
    print("  telefon serverga yetib kelmayapti (Wi-Fi yoki firewall).")
    print("=" * 56, flush=True)

    import uvicorn

    from app.main import app

    uvicorn.run(app, host="0.0.0.0", port=PORT, loop="asyncio", http="h11", ws="none", log_level="info")


if __name__ == "__main__":
    main()
