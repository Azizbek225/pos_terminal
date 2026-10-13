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
