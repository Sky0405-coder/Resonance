#!/usr/bin/env bash
set -euo pipefail
APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$APP_DIR/tools/tizen-tools.sh"
if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "Aufruf: $0 <tv-ip>" >&2; exit 1; fi
TV_IP=$1
PACKAGE="$APP_DIR/Resonance.wgt"
[[ -f "$PACKAGE" ]] || { echo 'Zuerst TIZEN_PROFILE=Profil ./build.sh ausführen.' >&2; exit 1; }
# Fail before connecting if only the unsigned development ZIP exists.
python3 - "$PACKAGE" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as package:
    if not {'author-signature.xml', 'signature1.xml'}.issubset(package.namelist()):
        sys.exit('TV benötigt ein signiertes WGT. TIZEN_PROFILE=Profil ./build.sh ausführen.')
PY
SDB_BIN=$(find_sdb) || { echo 'sdb fehlt. VS-Code-Tizen-SDK installieren oder SDB setzen.' >&2; exit 1; }
"$SDB_BIN" connect "$TV_IP:26101"
SERIAL="$TV_IP:26101"
"$SDB_BIN" -s "$SERIAL" get-state
# vd_appinstall/was_execute is what works on the GQ55Q80TG (Tizen 5.5); `tz install` is not needed.
REMOTE=/home/owner/share/tmp/sdk_tools/tmp/Resonance.wgt
"$SDB_BIN" -s "$SERIAL" push "$PACKAGE" "$REMOTE"
"$SDB_BIN" -s "$SERIAL" shell 0 vd_appinstall KnodeReso1.Resonance "$REMOTE"
"$SDB_BIN" -s "$SERIAL" shell 0 was_execute KnodeReso1.Resonance
