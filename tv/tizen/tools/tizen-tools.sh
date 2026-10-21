#!/usr/bin/env bash
# Shared discovery. Overrides must be absolute executable paths.
find_tizen_cli() {
  local candidate
  if [[ -n "${TIZEN_CLI:-}" ]]; then
    [[ -x "$TIZEN_CLI" ]] || { echo "TIZEN_CLI ist nicht ausführbar: $TIZEN_CLI" >&2; return 1; }
    printf '%s\n' "$TIZEN_CLI"; return
  fi
  if command -v tizen >/dev/null 2>&1; then command -v tizen; return; fi
  for candidate in \
    "$HOME/.tizen-extension-platform/server/sdktools/data/tools/ide/bin/tizen" \
    "$HOME/tizen-studio/tools/ide/bin/tizen" \
    "$HOME/tizentv-tools/tizen" "$HOME/tizentv-tools/bin/tizen" \
    "$HOME/tizentv-tools/tools/ide/bin/tizen" \
    "$HOME/.tizen-extension-platform/server/sdktools/data/tools/tizen-core/tz" \
    "$HOME/tizentv-tools/tz"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  done
  if [[ -d "$HOME/tizentv-tools" ]]; then
    candidate=$(find "$HOME/tizentv-tools" -maxdepth 5 -type f \( -name tizen -o -name tz \) -executable -print -quit)
    if [[ -n "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  fi
  return 1
}
find_sdb() {
  local candidate
  if [[ -n "${SDB:-}" ]]; then [[ -x "$SDB" ]] && printf '%s\n' "$SDB"; return; fi
  if command -v sdb >/dev/null 2>&1; then command -v sdb; return; fi
  for candidate in "$HOME/.tizen-extension-platform/server/sdktools/data/tools/sdb" "$HOME/tizen-studio/tools/sdb" "$HOME/tizentv-tools/sdb/sdb"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  done
  return 1
}
