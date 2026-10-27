"""Tests ohne Internet: yt-dlp wird durch ein kleines Skript ersetzt, das eine Datei schreibt."""

import os
import sys
import tempfile
from pathlib import Path

tmp = Path(tempfile.mkdtemp())
fake = tmp / "fake_ytdlp.py"
fake.write_text(
    "import sys,pathlib\n"
    "a=sys.argv[1:]\n"
    "if '--version' in a: print('fake-1.0'); sys.exit(0)\n"
    "url=a[-1]\n"
    "if url.endswith('FAILFAILFAI'): print('ERROR: Sign in to confirm', file=sys.stderr); sys.exit(1)\n"
    "out=a[a.index('-o')+1].replace('%(ext)s','m4a')\n"
    "pathlib.Path(out).write_bytes(bytes(range(256))*40)\n"
)
os.environ.update(LYRA_KEY="geheim", CACHE_DIR=str(tmp / "cache"), YTDLP_CMD=f"{sys.executable} {fake}")

from fastapi.testclient import TestClient  # noqa: E402

import app as server  # noqa: E402

c = TestClient(server.app)


def test_ohne_schluessel_abgelehnt():
    assert c.get("/audio/dQw4w9WgXcQ").status_code == 401
    assert c.get("/audio/dQw4w9WgXcQ?k=falsch").status_code == 401


def test_health():
    r = c.get("/health", headers={"X-Lyra-Key": "geheim"})
    assert r.status_code == 200 and r.json()["ytdlp"] == "fake-1.0"


def test_ungueltige_id():
    assert c.get("/audio/..%2Fetc", headers={"X-Lyra-Key": "geheim"}).status_code in (400, 404)


def test_audio_und_range():
    r = c.get("/audio/dQw4w9WgXcQ?k=geheim")
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/mp4"
    assert len(r.content) == 256 * 40
    assert (tmp / "cache" / "dQw4w9WgXcQ.m4a").exists()
    r = c.get("/audio/dQw4w9WgXcQ", headers={"X-Lyra-Key": "geheim", "Range": "bytes=100-"})
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes 100-{256 * 40 - 1}/{256 * 40}"
    assert r.content[0] == 100
    assert "no-store" in r.headers["cache-control"]


def test_fehler_von_ytdlp():
    r = c.get("/audio/FAILFAILFAI", headers={"X-Lyra-Key": "geheim"})
    assert r.status_code == 502 and "Sign in" in r.json()["detail"]
    assert not (tmp / "cache" / "FAILFAILFAI.m4a").exists()
