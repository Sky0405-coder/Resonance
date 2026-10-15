#!/bin/sh
# Release: bumps the version (1.0.N, N = build number), builds the signed APK, uploads it to the Resonance
# server (installed apps offer it as an in-app update), commits + tags the version and creates a GitHub
# release with the APK. Publishing the release triggers .github/workflows/desktop-release.yml, which adds
# the Linux and Windows builds.
#
# Needs: app/android/key.properties (release keystore), JAVA_HOME with JDK 17/21,
#        RESONANCE_URL (default https://resonance.k-node.de) and an admin token in RESONANCE_TOKEN
#        or ~/.config/resonance/server-token, and a logged-in `gh` for the GitHub release
#        (skipped with a warning otherwise).
set -eu
cd "$(dirname "$0")/../app"
URL=${RESONANCE_URL:-https://resonance.k-node.de}
TOKEN=${RESONANCE_TOKEN:-$(cat ~/.config/resonance/server-token)}
FLUTTER=${FLUTTER:-$HOME/flutter/bin/flutter}
GH=${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}

# version: 1.0.6+6 -> 1.0.7+7
current=$(sed -n 's/^version: //p' pubspec.yaml)
code=$(( ${current#*+} + 1 ))
name="1.0.$code"
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
  "$GH" release create "v$name" "/tmp/Resonance-v$name-android.apk" --title "Resonance $name" --generate-notes
  echo "GitHub release v$name created (Linux/Windows builds follow via GitHub Actions)"
else
  echo "WARNING: gh not logged in – no GitHub release created (run: gh auth login)" >&2
fi
