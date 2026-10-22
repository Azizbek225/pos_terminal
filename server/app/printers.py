"""Kompyuterga ulangan printerlar: telefon chekni server orqali chop etadi.

Ilova ESC/POS baytlarini tayyorlab yuboradi; server ularni Windows
spooler'iga RAW ko'rinishida beradi (macOS/Linux'da CUPS `lp -o raw`).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import threading

_lock = threading.Lock()


class PrintError(Exception):
    pass


def list_printers() -> list[str]:
    try:
        if sys.platform == "win32":
            r = subprocess.run(
                ["powershell", "-NoProfile", "-Command", "Get-Printer | Select-Object -ExpandProperty Name"],
                capture_output=True,
                text=True,
                timeout=20,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            return [line.strip() for line in r.stdout.splitlines() if line.strip()]
        r = subprocess.run(["lpstat", "-a"], capture_output=True, text=True, timeout=20)
        return [line.split(" ")[0] for line in r.stdout.splitlines() if line.strip()]
    except Exception:  # noqa: BLE001 — printer ro'yxati bo'lmasa ham server ishlayveradi
        return []


def print_raw(printer: str, data: bytes, doc_name: str = "POS chek") -> None:
    if not printer.strip():
        raise PrintError("Printer nomi berilmagan")
    with _lock:  # bir printerga navbat bilan
        if sys.platform == "win32":
            _print_windows(printer, data, doc_name)
        else:
            _print_cups(printer, data)


def _print_windows(printer: str, data: bytes, doc_name: str) -> None:
    import ctypes
    from ctypes import wintypes

    winspool = ctypes.WinDLL("winspool.drv")

    class DocInfo1(ctypes.Structure):
        _fields_ = [("pDocName", wintypes.LPWSTR), ("pOutputFile", wintypes.LPWSTR), ("pDatatype", wintypes.LPWSTR)]

    handle = wintypes.HANDLE()
    if not winspool.OpenPrinterW(printer, ctypes.byref(handle), None):
        raise PrintError(f'Printer topilmadi: "{printer}"')
    try:
        doc = DocInfo1(doc_name, None, "RAW")
        if not winspool.StartDocPrinterW(handle, 1, ctypes.byref(doc)):
            raise PrintError("StartDocPrinter xatosi")
        try:
            winspool.StartPagePrinter(handle)
            written = wintypes.DWORD()
            buf = ctypes.create_string_buffer(data, len(data))
            ok = winspool.WritePrinter(handle, buf, len(data), ctypes.byref(written))
            winspool.EndPagePrinter(handle)
        finally:
            winspool.EndDocPrinter(handle)
        if not ok or written.value != len(data):
            raise PrintError(f"Printerga yozib bo'lmadi ({written.value}/{len(data)})")
    finally:
        winspool.ClosePrinter(handle)


def _print_cups(printer: str, data: bytes) -> None:
    fd, path = tempfile.mkstemp(suffix=".bin")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        r = subprocess.run(["lp", "-d", printer, "-o", "raw", path], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            raise PrintError(f"CUPS xatosi: {r.stderr.strip()}")
    except FileNotFoundError as e:
        raise PrintError("Bu kompyuterda chop etish tizimi topilmadi") from e
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
