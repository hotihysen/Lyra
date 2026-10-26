#!/usr/bin/env bash
# Prüft die gebaute APK: Paketname, Versionscode/-name und Signatur gegen den festen Schlüssel.
# Aufruf: ci/apk_check.sh <apk> <erwarteter Build>
set -euo pipefail
APK="$1"
BUILD="$2"
BT=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)

BADGING=$("$BT/aapt2" dump badging "$APK" | head -1)
PKG=$(sed -n "s/.*package: name='\([^']*\)'.*/\1/p" <<<"$BADGING")
VC=$(sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" <<<"$BADGING")
VN=$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$BADGING")

APK_CERT=$("$BT/apksigner" verify --print-certs "$APK" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1 | tr -d ':' | tr 'A-F' 'a-f')
KEY_CERT=$(keytool -list -v -keystore ci/debug.keystore -storepass android -alias androiddebugkey 2>/dev/null \
  | sed -n 's/.*SHA256: //p' | head -1 | tr -d ':' | tr 'A-F' 'a-f')

SUMMARY="Paket: $PKG | versionCode: $VC | versionName: $VN | APK-Zertifikat SHA-256: $APK_CERT | Schlüssel ci/debug.keystore: $KEY_CERT"
echo "$SUMMARY"
echo "::notice title=APK-Prüfung::$SUMMARY"

FAIL=0
[ "$PKG" = "ch.hysen.lyra" ] || { echo "::error title=APK-Prüfung::Falscher Paketname $PKG"; FAIL=1; }
[ "$VC" = "$BUILD" ] || { echo "::error title=APK-Prüfung::versionCode $VC passt nicht zur Build-Nummer $BUILD"; FAIL=1; }
[ "$VN" = "1.0.$BUILD" ] || { echo "::error title=APK-Prüfung::versionName $VN passt nicht zu 1.0.$BUILD"; FAIL=1; }
[ -n "$APK_CERT" ] && [ "$APK_CERT" = "$KEY_CERT" ] || { echo "::error title=APK-Prüfung::Signatur passt nicht zum festen Schlüssel ($APK_CERT vs $KEY_CERT)"; FAIL=1; }
exit $FAIL
