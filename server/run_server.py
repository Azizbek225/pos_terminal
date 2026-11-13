"""Windows uchun bitta faylli server (PosServer.exe) ishga tushirgichi.

Docker va PostgreSQL kerak emas: baza (pos.db) va API kalit (api_kalit.txt)
exe yonidagi papkada saqlanadi. Ishga tushganda kompyuter IP manzili va
kalit ekranga chiqadi — ularni telefondagi Sozlamalar > Sinxronlash ga yozing.

    python run_server.py          # yoki PyInstaller bilan yig'ilgan PosServer.exe
    PosServer.exe --autostart-off # Windows bilan avtomatik ishga tushishni o'chirish
    PosServer.exe --init          # (PosSetup) kalit yaratish va firewall ruxsati, keyin chiqish
    PosServer.exe --internet      # internetga ochish ustasini darhol boshlash (Tailscale)

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
import time
from pathlib import Path

from app.netinfo import local_ips

PORT = int(os.environ.get("POS_PORT", "8000"))
DISCOVERY_PORT = int(os.environ.get("POS_DISCOVERY_PORT", "8765"))
DISCOVERY_MAGIC = b"POS_DISCOVER"
AUTOSTART_NAME = "PosServer"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
# Oynasiz server qora oyna chaqnatmasin.
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


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
                capture_output=True, creationflags=NO_WINDOW,
            ).returncode == 0
            if exists:
                continue
            argv = ["netsh", "advfirewall", "firewall", "add", "rule", f"name={name}", "dir=in", "action=allow",
                    f"protocol={proto}", f"localport={port}", "profile=any"]
            if subprocess.run(argv, capture_output=True, creationflags=NO_WINDOW).returncode != 0:
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


def open_connect_page(port: int = PORT) -> None:
    """Qo'lda ishga tushirilganda QR kodli ulash sahifasini brauzerda ochish
    (Windows yonganda avtomatik ishga tushishda ochilmaydi)."""
    import webbrowser

    def go() -> None:
        for _ in range(30):
            if already_running(port):
                webbrowser.open(f"http://localhost:{port}/ulash")
                return
            time.sleep(0.5)

    threading.Thread(target=go, name="pos-open-browser", daemon=True).start()


def set_title(text: str) -> None:
    if os.name != "nt":
        return
    try:
        import ctypes

        ctypes.windll.kernel32.SetConsoleTitleW(text)
    except (OSError, AttributeError):
        pass


_NET_REASON = {
    "not_installed": "Tailscale o'rnatilmagan",
    "stopped": "Tailscale ishlamayapti",
    "need_login": "Tailscale'ga kirilmagan",
    "off": "o'chirilgan",
}


def internet_line(st: dict) -> str:
    """Server oynasidagi internet holati qatori."""
    if st.get("state") == "on":
        return f"INTERNET: YOQIQ  {st.get('url')}/"
    reason = _NET_REASON.get(st.get("state"), "noma'lum")
    return f"INTERNET: o'chiq ({reason}). Yoqish: http://localhost:{PORT}/ulash"


def watch_internet(port: int = PORT, interval: float = 60) -> None:
    """Internet holati o'zgarganda oynaga yozadi va sarlavhada doim ko'rsatadi."""
    from app import funnel

    last = None
    while True:
        try:
            line = internet_line(funnel.status(port, fresh=True))
        except Exception as e:  # noqa: BLE001
            line = f"INTERNET: tekshirib bo'lmadi ({e})"
        if line != last:
            print(f"  [{time.strftime('%H:%M')}] {line}", flush=True)
            set_title("PosServer - " + line.split("  ")[0].split(" (")[0])
            last = line
        time.sleep(interval)


def start_internet_wizard(port: int = PORT) -> None:
    import webbrowser

    from app import funnel

    for _ in range(60):
        if already_running(port):
            break
        time.sleep(0.5)
    if funnel.status(port, fresh=True).get("state") != "on":
        funnel.start_wizard(port, webbrowser.open)


def setup_log(folder: Path) -> None:
    """Oynasiz (fon) rejimda chiqish `server.log` ga yoziladi."""
    if sys.stdout is not None and sys.stderr is not None:
        return
    log = folder / "server.log"
    try:
        if log.exists() and log.stat().st_size > 5 * 1024 * 1024:
            log.replace(folder / "server.old.log")
        f = open(log, "a", encoding="utf-8", buffering=1)  # noqa: SIM115 — jarayon oxirigacha ochiq
    except OSError:
        f = open(os.devnull, "w", encoding="utf-8")  # noqa: SIM115
    sys.stdout = sys.stdout or f
    sys.stderr = sys.stderr or f


def ask_running_server(port: int, internet: bool, show_page: bool) -> None:
    """Server allaqachon fonda ishlayapti: boshqaruv sahifasini ochish va
    (kerak bo'lsa) internetga ochish ustasini boshlash."""
    import urllib.request
    import webbrowser

    if internet:
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/funnel", data=b'{"on": true}',
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            urllib.request.urlopen(req, timeout=30).read()
        except OSError as e:
            print(f"Internet ustasi boshlanmadi: {e}")
    if show_page:
        webbrowser.open(f"http://localhost:{port}/ulash")


def main() -> None:
    args = set(sys.argv[1:])
    setup_log(base_dir())
    if "--autostart-off" in args:
        ok = set_autostart(False)
        print("Avtomatik ishga tushish o'chirildi." if ok else "Faqat Windows'dagi PosServer.exe uchun.")
        return
    if "--init" in args:
        # PosSetup administrator huquqida chaqiradi: firewall so'rovi keyin chiqmaydi,
        # kassa ilovasi esa birinchi ochilishdayoq kalitni topadi.
        folder = base_dir()
        os.chdir(folder)
        load_api_key(folder)
        open_firewall()
        return
    minimized = "--minimized" in args
    if minimized:
        minimize_console()
    if already_running():
        # "POS Server" belgisi qayta bosilsa — boshqaruv (QR) sahifasi ochiladi.
        print(f"PosServer allaqachon ishlayapti (port {PORT}).")
        ask_running_server(PORT, "--internet" in args, not minimized)
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
    print(f"  DASTUR (brauzerda): http://{ips[0]}:{PORT}")
    for ip in ips[1:]:
        print(f"  (yoki             : http://{ip}:{PORT})")
    print("  Shu manzilni istalgan kompyuter yoki telefon brauzerida oching")
    print("  va ilovadagi login/parol bilan kiring - boshqa sozlash kerak emas.")
    print()
    print(f"  Ilovani ulash (QR) : brauzerda http://localhost:{PORT}/ulash")
    print(f"  API kalit          : {os.environ['POS_API_KEY']}")
    print()
    print("  Server fonda ishlaydi (oynasi yo'q). Boshqaruv: http://localhost:8000/ulash")
    if autostart:
        print("  Windows yonganda server o'zi ishga tushadi.")
        print("  (O'chirish: PosServer.exe --autostart-off)")
    print("  IP o'zgarsa telefon serverni o'zi qayta topadi.")
    print("  Pastda har bir qurilma ulanganda qator chiqadi:")
    print("  push = yubordi, pull = oldi. Telefon IP si ko'rinmasa,")
    print("  telefon serverga yetib kelmayapti (Wi-Fi yoki firewall).")
    print("=" * 56, flush=True)

    if not minimized:
        open_connect_page()
    threading.Thread(target=watch_internet, name="pos-funnel", daemon=True).start()
    if "--internet" in args:
        # PosSetup'da "Internetdan ham ishlasin" tanlangan: usta o'zi boshlanadi
        # (Tailscale'ga kirish va ruxsat sahifalari brauzerda ochiladi).
        threading.Thread(target=start_internet_wizard, name="pos-wizard", daemon=True).start()

    import uvicorn

    from app.main import app

    uvicorn.run(app, host="0.0.0.0", port=PORT, loop="asyncio", http="h11", ws="none", log_level="info")


if __name__ == "__main__":
    main()
