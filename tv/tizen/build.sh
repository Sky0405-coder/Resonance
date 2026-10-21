#!/usr/bin/env bash
set -euo pipefail
APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$APP_DIR/tools/tizen-tools.sh"
node "$APP_DIR/check-syntax.mjs"
STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
mkdir "$STAGE/app"
cp "$APP_DIR/config.xml" "$APP_DIR/index.html" "$APP_DIR/icon.png" "$STAGE/app/"
cp -R "$APP_DIR/css" "$APP_DIR/js" "$STAGE/app/"
(cd "$STAGE/app" && zip -q -r "$STAGE/unsigned.wgt" .)
if [[ -n "${TIZEN_PROFILE:-}" ]]; then
  CLI=$(find_tizen_cli) || { echo 'Kein Signierwerkzeug gefunden. Tizen Web CLI installieren oder TIZEN_CLI setzen.' >&2; exit 1; }
  mkdir "$STAGE/signed"
  if [[ "$(basename "$CLI")" == tz ]]; then
    ARGS=(pack --type wgt --sign-profile "$TIZEN_PROFILE" --base-pkg "$STAGE/unsigned.wgt" --out-path "$STAGE/signed/Resonance.wgt")
    if [[ -n "${TIZEN_PROFILES_PATH:-}" ]]; then ARGS+=(--profiles-path "$TIZEN_PROFILES_PATH"); fi
    "$CLI" "${ARGS[@]}"
  else
    if [[ -n "${TIZEN_PROFILES_PATH:-}" ]]; then
      echo 'TIZEN_PROFILES_PATH wird nur von tz unterstützt; Profil bei der klassischen tizen-CLI registrieren.' >&2; exit 1
    fi
    "$CLI" package -t wgt -s "$TIZEN_PROFILE" -o "$STAGE/signed" -- "$STAGE/app"
  fi
  SIGNED=$(find "$STAGE/signed" -maxdepth 1 -type f -name '*.wgt' -print -quit)
  [[ -n "$SIGNED" ]] || { echo 'Signierwerkzeug hat kein WGT erzeugt.' >&2; exit 1; }
  python3 - "$SIGNED" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as package:
    names = package.namelist()
    if 'author-signature.xml' not in names or 'signature1.xml' not in names:
        sys.exit('Signiertes Paket enthält nicht beide erforderlichen Signaturen.')
PY
  cp "$SIGNED" "$APP_DIR/Resonance.wgt"
  echo "Signiert mit Profil $TIZEN_PROFILE: $APP_DIR/Resonance.wgt"
else
  cp "$STAGE/unsigned.wgt" "$APP_DIR/Resonance.wgt"
  echo "UNSIGNIERT: $APP_DIR/Resonance.wgt — für TV-Installation mit TIZEN_PROFILE erneut bauen."
fi
