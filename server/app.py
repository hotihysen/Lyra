"""Lyra-Server: holt das Audio zu einer YouTube-Music-ID und liefert es an die App.

Läuft als Docker-Container (zum Beispiel auf Unraid). Das Audio wird mit yt-dlp über den
Internetanschluss des Servers geladen, als M4A (AAC) zwischengespeichert und mit
Range-Unterstützung ausgeliefert. M4A spielt auf iPhone und Android.

Umgebungsvariablen:
  LYRA_KEY        Pflicht. Geheimer Schlüssel; die App schickt ihn mit jeder Anfrage.
  CACHE_DIR       Zwischenspeicher (Standard /cache).
  CACHE_MAX_GB    Grösse des Zwischenspeichers, älteste Dateien werden zuerst gelöscht (Standard 5).
  YTDLP_UPDATE    "1" (Standard): yt-dlp beim Start und täglich aktualisieren.
  COOKIES_FILE    Optional: Cookies im Netscape-Format, falls YouTube den Server sperrt.
"""

import asyncio
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse

KEY = os.environ.get("LYRA_KEY", "").strip()
CACHE = Path(os.environ.get("CACHE_DIR", "/cache"))
CACHE_MAX = float(os.environ.get("CACHE_MAX_GB", "5")) * 1024**3
COOKIES = os.environ.get("COOKIES_FILE", "/cache/cookies.txt")
# Für Tests kann ein anderer Befehl statt yt-dlp gesetzt werden
YTDLP = os.environ.get("YTDLP_CMD", f"{sys.executable} -m yt_dlp").split()
VID = re.compile(r"^[A-Za-z0-9_-]{11}$")

CACHE.mkdir(parents=True, exist_ok=True)
app = FastAPI(title="Lyra-Server", docs_url=None, redoc_url=None)
_locks: dict[str, asyncio.Lock] = {}
_last_error = ""


def _check(request: Request) -> None:
    if not KEY:
        raise HTTPException(500, "LYRA_KEY ist nicht gesetzt")
    got = request.headers.get("x-lyra-key") or request.query_params.get("k") or ""
    if not hmac.compare_digest(got.encode(), KEY.encode()):
        raise HTTPException(401, "Falscher Schlüssel")


def _ytdlp_version() -> str:
    try:
        return subprocess.run(YTDLP + ["--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception as e:  # noqa: BLE001
        return f"nicht verfügbar ({e})"


def _update_loop() -> None:
    while True:
        try:
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "-q", "-U", "--no-cache-dir", "yt-dlp[default]"],
                capture_output=True, timeout=300,
            )
        except Exception:  # noqa: BLE001
            pass
        time.sleep(24 * 3600)


if os.environ.get("YTDLP_UPDATE", "1") == "1" and "YTDLP_CMD" not in os.environ:
    threading.Thread(target=_update_loop, daemon=True).start()


def _trim_cache() -> None:
    files = [p for p in CACHE.glob("*.m4a") if p.is_file()]
    total = sum(p.stat().st_size for p in files)
    for p in sorted(files, key=lambda p: p.stat().st_atime):
        if total <= CACHE_MAX:
            break
        total -= p.stat().st_size
        p.unlink(missing_ok=True)


def _fetch(vid: str, target: Path) -> None:
    """Lädt das Audio mit yt-dlp und legt es als M4A ab."""
    global _last_error
    work = CACHE / f".{vid}.tmp"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    try:
        cmd = YTDLP + [
            "--no-playlist", "--no-progress", "--quiet", "--no-warnings",
            # AAC bevorzugen (iPhone spielt kein Opus/WebM); sonst bestes Audio und umwandeln
            "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio",
            "-x", "--audio-format", "m4a", "--audio-quality", "0",
            "-o", str(work / "a.%(ext)s"),
        ]
        if os.path.isfile(COOKIES):
            cmd += ["--cookies", COOKIES]
        cmd.append(f"https://music.youtube.com/watch?v={vid}")
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        out = list(work.glob("a.m4a")) or list(work.glob("a.*"))
        if r.returncode != 0 or not out or out[0].stat().st_size == 0:
            _last_error = (r.stderr or r.stdout or "keine Datei").strip()[-800:]
            raise HTTPException(502, f"yt-dlp: {_last_error.splitlines()[-1] if _last_error else 'Fehler'}")
        os.replace(out[0], target)
        _last_error = ""
    finally:
        shutil.rmtree(work, ignore_errors=True)


@app.get("/")
def root() -> PlainTextResponse:
    return PlainTextResponse("Lyra-Server läuft.")


@app.get("/health")
def health(request: Request) -> JSONResponse:
    _check(request)
    files = list(CACHE.glob("*.m4a"))
    return JSONResponse({
        "ok": True,
        "ytdlp": _ytdlp_version(),
        "cacheFiles": len(files),
        "cacheMB": round(sum(p.stat().st_size for p in files) / 1024**2),
        "lastError": _last_error,
    })


@app.get("/audio/{vid}")
async def audio(vid: str, request: Request):
    _check(request)
    vid = vid.removesuffix(".m4a")
    if not VID.match(vid):
        raise HTTPException(400, "Ungültige ID")
    target = CACHE / f"{vid}.m4a"
    if not target.exists():
        lock = _locks.setdefault(vid, asyncio.Lock())
        async with lock:
            if not target.exists():
                await asyncio.to_thread(_fetch, vid, target)
                await asyncio.to_thread(_trim_cache)
        _locks.pop(vid, None)
    try:
        os.utime(target)  # für die Reihenfolge beim Aufräumen
    except OSError:
        pass
    return FileResponse(
        target,
        media_type="audio/mp4",
        # Nicht bei Cloudflare zwischenspeichern
        headers={"Cache-Control": "private, no-store", "Accept-Ranges": "bytes"},
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
