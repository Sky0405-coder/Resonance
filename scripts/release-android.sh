#!/bin/sh
# Builds a signed release APK, bumps the build number and uploads it to the Resonance server,
# from where installed apps offer it as an in-app update.
#
# Needs: app/android/key.properties (release keystore), JAVA_HOME with JDK 17/21,
#        RESONANCE_URL (default https://resonance.k-node.de) and an admin token in RESONANCE_TOKEN
#        or ~/.config/resonance/server-token.
set -eu
cd "$(dirname "$0")/../app"
URL=${RESONANCE_URL:-https://resonance.k-node.de}
TOKEN=${RESONANCE_TOKEN:-$(cat ~/.config/resonance/server-token)}
FLUTTER=${FLUTTER:-$HOME/flutter/bin/flutter}

# version: 1.2.3+45 -> 1.2.3+46
current=$(sed -n 's/^version: //p' pubspec.yaml)
name=${current%+*}
code=$(( ${current#*+} + 1 ))
sed -i "s/^version: .*/version: $name+$code/" pubspec.yaml
echo "Building $name ($code) ..."

"$FLUTTER" build apk --release
apk=build/app/outputs/flutter-apk/app-release.apk
curl -fsS -X PUT "$URL/api/admin/app/android" -H "Authorization: Bearer $TOKEN" \
  -F "version_name=$name" -F "version_code=$code" -F "file=@$apk;type=application/vnd.android.package-archive"
echo
cp "$apk" "$HOME/Downloads/Resonance.apk"
echo "Uploaded $name ($code); also copied to ~/Downloads/Resonance.apk"
