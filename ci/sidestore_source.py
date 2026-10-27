"""Erzeugt die SideStore-/AltStore-Quelle (source.json) für die aktuelle Version.

Aufruf: python3 ci/sidestore_source.py VERSION BUILD IPA-DATEI REPO
Die Datei wird an jedes Release gehängt; SideStore liest sie über
https://github.com/REPO/releases/latest/download/source.json
"""

import datetime
import json
import os
import sys

version, build, ipa, repo = sys.argv[1:5]
base = f"https://github.com/{repo}"
src = {
    "name": "Lyra",
    "identifier": "ch.hysen.lyra.source",
    "subtitle": "Musik und Hörbücher",
    "sourceURL": f"{base}/releases/latest/download/source.json",
    "iconURL": f"https://raw.githubusercontent.com/{repo}/main/ci/ios/AppIcon-1024.png",
    "website": base,
    "tintColor": "#8B5CF6",
    "apps": [{
        "name": "Lyra",
        "bundleIdentifier": "ch.hysen.lyra",
        "developerName": "Hysen",
        "subtitle": "Musik und Hörbücher",
        "localizedDescription": "Privates Lernprojekt. Katalog von YouTube Music, Hörbücher von LibriVox, Offline-Downloads.",
        "iconURL": f"https://raw.githubusercontent.com/{repo}/main/ci/ios/AppIcon-1024.png",
        "tintColor": "#8B5CF6",
        "category": "entertainment",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.date.today().isoformat(),
            "localizedDescription": f"Lyra {version}",
            "downloadURL": f"{base}/releases/download/v{version}/{os.path.basename(ipa)}",
            "size": os.path.getsize(ipa),
            "minOSVersion": "13.0",
        }],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}
with open("source.json", "w") as f:
    json.dump(src, f, indent=2, ensure_ascii=False)
print(json.dumps(src, indent=2, ensure_ascii=False))
