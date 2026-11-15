"""Zaxira nusxalar: soatlik nusxa, tozalash, Google Drive papkasi, tiklash."""

import zipfile
from datetime import datetime, timedelta

import pytest

from .test_sync import H, client, fresh_db, product, push  # noqa: F401 — muhit o'zgaruvchilari app'dan oldin

from app import backup, web  # noqa: E402


@pytest.fixture(autouse=True)
def _local(request, monkeypatch):
    # Server kompyuterining o'zidan kelgandek (oxirgi testdan tashqari).
    if request.node.name != "test_remote_needs_owner":
        monkeypatch.setattr(web, "_is_local", lambda request: True)


def test_rotation_keeps_24_hourly_30_daily_12_monthly():
    start = datetime(2025, 1, 1)
    names = [f"pos_{backup._stamp(start + timedelta(hours=h))}.zip" for h in range(24 * 500)]
    keep = backup.to_keep(names + ["boshqa-fayl.zip"])
    newest = sorted(names)[-24:]
    assert set(newest) <= keep
    days = {n[4:14] for n in keep}
    months = {n[4:11] for n in keep}
    assert len(keep) <= 24 + 30 + 12
    assert len(days) >= 30 and len(months) == 12
    assert "boshqa-fayl.zip" not in keep


def test_detect_drive(tmp_path):
    (tmp_path / "G" / "My Drive").mkdir(parents=True)
    assert backup.detect_drive([tmp_path / "X", tmp_path / "G"]) == tmp_path / "G" / "My Drive" / backup.DRIVE_SUBDIR
    assert backup.detect_drive([tmp_path / "X"]) is None


def test_backup_only_when_changed_and_drive_copy(client, tmp_path):  # noqa: F811
    folder, drive_root = tmp_path / "nusxa", tmp_path / "My Drive"
    drive_root.mkdir()
    r = client.post("/api/backup/settings", json={"dir": str(folder), "drive_dir": str(drive_root / "POS nusxalar")})
    assert r.status_code == 200, r.text

    push(client, [product("p1")])
    first = backup.make_backup(now=datetime(2026, 11, 15, 10, 0, 0))
    assert first["ok"] and not first["skipped"] and first["drive"]
    assert backup.make_backup(now=datetime(2026, 11, 15, 11, 0, 0))["skipped"]  # o'zgarish yo'q

    push(client, [product("p2", name="Tog'ora")])
    assert not backup.make_backup(now=datetime(2026, 11, 15, 12, 0, 0))["skipped"]

    st = client.get("/api/backup").json()
    assert [f["name"] for f in st["local"]] == ["pos_2026-11-15_12-00-00.zip", "pos_2026-11-15_10-00-00.zip"]
    assert len(st["drive"]) == 2 and not st["error"] and not st["drive_error"]
    with zipfile.ZipFile(folder / "pos_2026-11-15_10-00-00.zip") as z:
        assert z.namelist() == ["pos.db"]

    r = client.get("/api/backup/file", params={"name": "pos_2026-11-15_10-00-00.zip"})
    assert r.status_code == 200 and r.content[:2] == b"PK"
    assert client.get("/api/backup/file", params={"name": "../pos.db"}).status_code == 404


def test_missing_drive_folder_is_reported(client, tmp_path):  # noqa: F811
    r = client.post("/api/backup/settings", json={"dir": str(tmp_path), "drive_dir": str(tmp_path / "yoq" / "POS")})
    assert r.status_code == 422


def test_restore_brings_back_old_data_and_new_server_id(client, tmp_path):  # noqa: F811
    client.post("/api/backup/settings", json={"dir": str(tmp_path)})
    push(client, [product("p1")])
    old_id = client.get("/api/health").json()["server_id"]
    name = client.post("/api/backup/now").json()["name"]

    push(client, [product("p2", name="Keyin qo'shilgan")])
    r = client.post("/api/backup/restore", json={"name": name})
    assert r.status_code == 200, r.text
    assert r.json()["safety"].endswith("_tiklashdan-oldin.zip")

    ids = {c["id"] for c in client.get("/api/sync/pull", params={"since": 0}, headers=H).json()["changes"]}
    assert ids == {"p1"}
    assert client.get("/api/health").json()["server_id"] != old_id
    # Ilova keyin qayta yuborsa — qabul qilinadi.
    push(client, [product("p2", name="Keyin qo'shilgan")])


def test_remote_needs_owner(client):  # noqa: F811
    r = client.get("/api/backup")
    assert r.status_code in (401, 403)
