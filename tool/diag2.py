"""Testet Ausweichquellen für Musik-Audio (nur in GitHub Actions)."""
import json, urllib.request, urllib.parse, time

VID = "5NV6Rdv1a3I"  # Daft Punk - Get Lucky (Official Audio)
out = []

def log(s):
    print(s)
    out.append(s)

def get(url, headers=None, timeout=15, raw=False, rng=None):
    h = {"User-Agent": "Mozilla/5.0 Lyra"}
    if headers: h.update(headers)
    if rng: h["Range"] = rng
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(70000 if raw else 10_000_000)
        return r.status, (data if raw else json.loads(data.decode("utf-8", "replace")))

# --- Invidious ---
try:
    st, inst = get("https://api.invidious.io/instances.json?sort_by=health")
    hosts = [i[1]["uri"] for i in inst if i[1].get("type") == "https" and i[1].get("api")][:10]
    log(f"Invidious: {len(hosts)} Instanzen mit API")
    for h in hosts:
        try:
            st, v = get(f"{h}/api/v1/videos/{VID}?local=true", timeout=12)
            fm = [f for f in v.get("adaptiveFormats", []) if f.get("type", "").startswith("audio")]
            if not fm:
                log(f"  {h}: kein Audio"); continue
            url = fm[0]["url"]
            if url.startswith("/"): url = h + url
            st2, b = get(url, raw=True, rng="bytes=0-65535", timeout=12)
            log(f"  {h}: Audio {st2} {len(b)}B")
        except Exception as e:
            log(f"  {h}: FEHLER {str(e)[:70]}")
except Exception as e:
    log(f"Invidious Liste FEHLER {e}")

# --- Piped ---
try:
    st, inst = get("https://piped-instances.kavin.rocks/")
    apis = [i["api_url"] for i in inst][:10]
    log(f"Piped: {len(apis)} Instanzen")
    for a in apis:
        try:
            st, v = get(f"{a}/streams/{VID}", timeout=12)
            au = v.get("audioStreams", [])
            if not au:
                log(f"  {a}: kein Audio ({str(v)[:60]})"); continue
            st2, b = get(au[0]["url"], raw=True, rng="bytes=0-65535", timeout=12)
            log(f"  {a}: Audio {st2} {len(b)}B")
        except Exception as e:
            log(f"  {a}: FEHLER {str(e)[:70]}")
except Exception as e:
    log(f"Piped Liste FEHLER {e}")

# --- JioSaavn ---
def saavn(q):
    base = "https://www.jiosaavn.com/api.php?"
    p = {"__call": "search.getResults", "_format": "json", "_marker": "0", "api_version": "4", "ctx": "web6dot0", "n": "5", "p": "1", "q": q}
    st, r = get(base + urllib.parse.urlencode(p))
    res = r.get("results", [])
    if not res:
        log(f"JioSaavn «{q}»: keine Treffer"); return
    s = res[0]
    enc = s.get("more_info", {}).get("encrypted_media_url")
    log(f"JioSaavn «{q}»: {s.get('title')} / {s.get('more_info',{}).get('music', s.get('subtitle'))} dur={s.get('more_info',{}).get('duration')}")
    p2 = {"__call": "song.generateAuthToken", "url": enc, "bitrate": "320", "api_version": "4", "_format": "json", "ctx": "web6dot0", "_marker": "0"}
    st, t = get(base + urllib.parse.urlencode(p2))
    au = t.get("auth_url")
    if not au:
        log(f"  kein auth_url: {str(t)[:80]}"); return
    st2, b = get(au, raw=True, rng="bytes=0-65535")
    log(f"  Stream {st2} {len(b)}B {au.split('?')[0][-40:]}")

for q in ["Get Lucky Daft Punk", "Menime Kida", "Blinding Lights The Weeknd"]:
    try:
        saavn(q)
    except Exception as e:
        log(f"JioSaavn «{q}» FEHLER {str(e)[:80]}")

open("diag.txt", "w").write("\n".join(out))
