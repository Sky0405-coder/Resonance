#!/bin/sh
# Add an entry in app/assets/changelog.json for the new version before releasing.
# Release: bumps the version (patch +1, or VERSION=x.y.z; the build number always +1), builds the signed APK,
# uploads it to the Resonance server (installed apps offer it as an in-app update), commits + tags the version
# and creates a GitHub release with the APK. Publishing it triggers .github/workflows/desktop-release.yml, which adds
# the Linux, Windows and iOS builds.
#
# Needs: app/android/key.properties (release keystore), JAVA_HOME with JDK 17/21,
#        RESONANCE_URL (default https://resonance.k-node.de) and an admin token in RESONANCE_TOKEN
#        or ~/.config/resonance/server-token, and a logged-in `gh` for the GitHub release
#        (skipped with a warning otherwise).
set -eu
cd "$(dirname "$0")/../app"
URL=${RESONANCE_URL:-https://resonance.k-node.de}
FLUTTER=${FLUTTER:-$HOME/flutter/bin/flutter}
GH=${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}

# version: 1.1.0+22 -> 1.1.1+23 (build number always +1); VERSION=1.2.0 sets the version name explicitly.
current=$(sed -n 's/^version: //p' pubspec.yaml)
code=$(( ${current#*+} + 1 ))
base=${current%+*}
name=${VERSION:-${base%.*}.$(( ${base##*.} + 1 ))}
python3 - "$name" <<'PY'
import json
import sys

version = sys.argv[1]
try:
    with open('assets/changelog.json', encoding='utf-8') as source:
        entries = json.load(source)
    if not isinstance(entries, list) or not any(
        isinstance(entry, dict) and entry.get('version') == version for entry in entries
    ):
        raise ValueError(f'no entry for version {version}')
except (OSError, ValueError) as error:
    sys.exit(f'Release blocked: app/assets/changelog.json: {error}. Add the changelog entry before releasing.')
PY
TOKEN=${RESONANCE_TOKEN:-$(cat ~/.config/resonance/server-token)}
sed -i "s/^version: .*/version: $name+$code/" pubspec.yaml
echo "Building $name ..."

"$FLUTTER" build apk --release
apk=build/app/outputs/flutter-apk/app-release.apk
curl -fsS --retry 10 --retry-delay 15 --retry-all-errors -X PUT "$URL/api/admin/app/android" \
  -H "Authorization: Bearer $TOKEN" \
  -F "version_name=$name" -F "version_code=$code" -F "file=@$apk;type=application/vnd.android.package-archive"
echo
cp "$apk" "$HOME/Downloads/Resonance.apk"
echo "Uploaded $name to $URL; also copied to ~/Downloads/Resonance.apk"

git add pubspec.yaml
git commit -q -m "Release $name" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag "v$name"
git push -q origin HEAD "v$name"

if [ -x "$GH" ] && "$GH" auth status >/dev/null 2>&1; then
  cp "$apk" "/tmp/Resonance-v$name-android.apk"
  tv_wgt=""
  # The Samsung TV package goes out unsigned: Samsung signatures only work on the signer's own TVs.
  tizen="$(cd .. && pwd)/tv/tizen"
  if command -v node >/dev/null && command -v zip >/dev/null && (cd "$tizen" && bash build.sh >/dev/null 2>&1); then
    mv "$tizen/Resonance.wgt" "/tmp/Resonance-v$name-samsung-tizen-unsigned.wgt"
    tv_wgt="/tmp/Resonance-v$name-samsung-tizen-unsigned.wgt"
  else
    echo "WARNING: Samsung TV package not built" >&2
  fi
  "$GH" release create "v$name" "/tmp/Resonance-v$name-android.apk" $tv_wgt --title "Resonance $name" --generate-notes
  echo "GitHub release v$name created (Linux/Windows builds follow via GitHub Actions)"
else
  echo "WARNING: gh not logged in – no GitHub release created (run: gh auth login)" >&2
fi
