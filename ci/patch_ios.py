"""Passt das von `flutter create --platforms=ios` erzeugte iOS-Gerüst für Lyra an."""

import json
import plistlib
import re
import shutil
import sys
from pathlib import Path

ios = Path("ios")
plist_path = ios / "Runner" / "Info.plist"
if not plist_path.exists():
    sys.exit("ios/Runner/Info.plist fehlt")

with plist_path.open("rb") as f:
    p = plistlib.load(f)
p["CFBundleDisplayName"] = "Lyra"
p["CFBundleName"] = "Lyra"
# Wiedergabe im Hintergrund und bei gesperrtem Bildschirm
p["UIBackgroundModes"] = ["audio"]
# Eigener Server darf auch ohne HTTPS im Heimnetz erreichbar sein
p["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoads": True}
p["ITSAppUsesNonExemptEncryption"] = False
p["UIStatusBarStyle"] = "UIStatusBarStyleLightContent"
p["UIViewControllerBasedStatusBarAppearance"] = False
with plist_path.open("wb") as f:
    plistlib.dump(p, f)

# App-Icon: eine Datei mit 1024 px, Xcode erzeugt die übrigen Grössen
icons = ios / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
shutil.rmtree(icons, ignore_errors=True)
icons.mkdir(parents=True)
shutil.copy("ci/ios/AppIcon-1024.png", icons / "AppIcon-1024.png")
(icons / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1},
}, indent=2))

# Mindestversion iOS 13
podfile = ios / "Podfile"
if podfile.exists():
    s = podfile.read_text()
    s = re.sub(r"^#?\s*platform :ios, '[0-9.]+'", "platform :ios, '13.0'", s, count=1, flags=re.M)
    podfile.write_text(s)

print("iOS-Gerüst angepasst")
