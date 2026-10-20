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
"$ADB" forward tcp:5277 tcp:5277
cd "$DHU"
LD_LIBRARY_PATH="$LIBCXX:$DHU" exec ./desktop-head-unit "$@"
