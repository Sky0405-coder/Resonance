#!/bin/sh
# Android Auto Desktop Head Unit (a car display on the desktop) for testing the app's Android Auto support.
#
# One-time setup on the phone (or an emulator with the Play Store and Android Auto installed):
#   1. Android Auto settings → tap "Version" 10× → developer settings are unlocked.
#   2. ⋮ → "Developer settings" → enable "Unknown sources" (needed for apps not from the Play Store).
#   3. ⋮ → "Start head unit server".
# Then connect the phone via USB (with USB debugging on) and run this script.
set -e
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
DHU="$SDK/extras/google/auto"
ADB="$SDK/platform-tools/adb"
if [ ! -x "$DHU/desktop-head-unit" ]; then
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" "extras;google;auto" >/dev/null
fi
# The DHU needs libc++, which Fedora does not ship by default; the NDK has it.
LIBCXX=$(dirname "$(find "$SDK/ndk" -path '*x86_64-unknown-linux-gnu/libc++.so.1' 2>/dev/null | head -1)")
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "Kein Handy gefunden: per USB anschließen und USB-Debugging erlauben." >&2
  exit 1
fi
# Without the head unit server the DHU connects to the forwarded port and quits silently right away.
if ! "$ADB" shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" | grep -qiE ':149D [0-9A-F]+:0000 0A'; then
  echo "Der Head-Unit-Server auf dem Handy läuft nicht." >&2
  echo "Android Auto öffnen → ⋮ → \"Server für Monitor starten\" (Start head unit server), dann erneut ausführen." >&2
  exit 1
fi
"$ADB" forward tcp:5277 tcp:5277
cd "$DHU"
# The DHU reads console commands from stdin and quits at its end; keep it open when started without a terminal.
if [ -t 0 ]; then
  LD_LIBRARY_PATH="$LIBCXX:$DHU" exec ./desktop-head-unit "$@"
fi
tail -f /dev/null | LD_LIBRARY_PATH="$LIBCXX:$DHU" ./desktop-head-unit "$@"
