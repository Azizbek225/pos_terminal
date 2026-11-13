"""PosServer.exe ishga tushirgichi: tarmoqda avtomatik topish."""

import json
import socket

import run_server


def _free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_discovery_replies_with_port():
    port = _free_udp_port()
    sock = run_server.start_discovery(port=8123, discovery_port=port)
    assert sock is not None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
            c.settimeout(3)
            c.sendto(b"boshqa narsa", ("127.0.0.1", port))
            c.sendto(run_server.DISCOVERY_MAGIC, ("127.0.0.1", port))
            data, _ = c.recvfrom(1024)
        info = json.loads(data)
        assert info["app"] == "pos-sync"
        assert info["port"] == 8123
    finally:
        sock.close()


def test_already_running_detects_listener():
    with socket.socket() as srv:
        srv.bind(("127.0.0.1", 0))
        srv.listen()
        assert run_server.already_running(srv.getsockname()[1])
    assert not run_server.already_running(_free_udp_port())


def test_autostart_is_windows_exe_only():
    assert run_server.set_autostart(True) is False


def test_init_creates_key_and_exits(monkeypatch, tmp_path):
    # PosSetup: --init kalit faylini yaratadi va server ishga tushmaydi.
    monkeypatch.setattr(run_server, "base_dir", lambda: tmp_path)
    monkeypatch.setattr(run_server.sys, "argv", ["PosServer.exe", "--init"])
    monkeypatch.delenv("POS_API_KEY", raising=False)
    monkeypatch.chdir(tmp_path)
    run_server.main()
    assert (tmp_path / "api_kalit.txt").read_text(encoding="utf-8").strip()


def test_internet_line():
    on = run_server.internet_line({"state": "on", "url": "https://kassa.tail1.ts.net"})
    assert on == "INTERNET: YOQIQ  https://kassa.tail1.ts.net/"
    off = run_server.internet_line({"state": "need_login"})
    assert off.startswith("INTERNET: o'chiq (Tailscale'ga kirilmagan)") and "/ulash" in off


def test_windowless_output_goes_to_log(monkeypatch, tmp_path):
    # PosServer.exe oynasiz yig'iladi: stdout yo'q — chiqish server.log ga.
    monkeypatch.setattr(run_server.sys, "stdout", None)
    monkeypatch.setattr(run_server.sys, "stderr", None)
    run_server.setup_log(tmp_path)
    print("salom")
    run_server.sys.stdout.flush()
    assert "salom" in (tmp_path / "server.log").read_text(encoding="utf-8")
