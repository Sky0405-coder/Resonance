# Phase 8d – Discord status on desktop (Flutter app + tiny backend part)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, existing style, `ruff format --line-length 120`, tests without network; run backend tests against the
database given in the task prompt only). App: all user-visible texts via gen-l10n (keys in **both**
`lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`),
`~/flutter/bin/flutter analyze` without issues, `~/flutter/bin/flutter test` passes,
`JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release`,
`~/flutter/bin/flutter build web --release --wasm` and `~/flutter/bin/flutter build linux --release` must succeed
(Linux build dependencies may be missing on the host – a container build like in phase 7c is fine). Do not touch
`docs/`, no release script, no upload/deploy. **No new native plugins / FFI packages**: pure Dart (`dart:io`).

## Goal
Like Spotify: while music plays in the **desktop** app (Linux, Windows), the user's Discord profile shows
"Listening to Resonance" with title, artist, album and a progress bar. Paused/stopped → status cleared.
Audiobooks: title + author, same behaviour. Web/Android: nothing (no code runs there).

## 1. Discord application id (backend)
Discord Rich Presence needs the id of a Discord "application" (created by the admin in the Discord developer
portal; the app's name – e.g. "Resonance" – is what Discord displays after "Listening to").
- `ServerConfig` new group `IntegrationsConfig` with `discord_client_id: str = ""` (digits only or empty,
  validate `^\d{0,24}$`), editable via the existing admin config API.
- New endpoint `GET /api/client-config` (any logged-in user) → `{"discord_client_id": "<id or empty>"}`.
- Admin page: new section "Integrationen" / "Integrations" with a `TextField` "Discord-Anwendungs-ID" /
  "Discord application ID", helper text "Für den Discord-Status der Desktop-App. Anwendung unter
  discord.com/developers anlegen und die Application ID hier eintragen." / "For the desktop app's Discord status.
  Create an application at discord.com/developers and enter its application ID here.", saved like the other
  text settings on the page.
- Test: config validation and the endpoint.

## 2. IPC client (`lib/integrations/discord_rpc.dart`, new)
Discord's local RPC: frames of `int32 little-endian opcode`, `int32 little-endian length`, UTF-8 JSON payload.
Opcodes: 0 HANDSHAKE, 1 FRAME, 2 CLOSE, 3 PING, 4 PONG.
- Connect: Linux – try for `n` in 0..9 the sockets `$XDG_RUNTIME_DIR/discord-ipc-n` (fallback dirs `$TMPDIR`,
  `/tmp`), then `$XDG_RUNTIME_DIR/app/com.discordapp.Discord/discord-ipc-n` (Flatpak) and
  `$XDG_RUNTIME_DIR/snap.discord/discord-ipc-n` (Snap); use `Socket.connect(InternetAddress(path, type:
  InternetAddressType.unix), 0)`. Windows – named pipe `\\.\pipe\discord-ipc-n`, opened with
  `File(path).open(mode: FileMode.append)` for writing and reading via a `RandomAccessFile` read loop (verify this
  works with `dart:io`; if it does not, implement Windows via `Process`-free alternatives only – document the
  result; Windows may then be left unsupported with a debug log, Linux must work).
- Handshake `{"v": 1, "client_id": "<id>"}` (opcode 0), wait for the READY dispatch.
- `setActivity(Map<String, dynamic>? activity)` → opcode 1
  `{"cmd": "SET_ACTIVITY", "args": {"pid": pid, "activity": activity}, "nonce": "<uuid>"}` (`activity: null` clears).
  Answer PING with PONG. On CLOSE / socket error: disconnect and retry connecting every 30 s while enabled.
- Rate limit: Discord allows 5 updates per 20 s – coalesce: keep only the latest pending activity and send at
  most one update every 4 s.

## 3. Presence controller (`lib/integrations/discord_presence.dart`, new)
Provider started in `main.dart` on Linux/Windows only, after login; stopped/cleared on logout.
- Enabled when the user setting is on (§4) **and** `discord_client_id` (from `/api/client-config`, fetched after
  login and on app start) is not empty.
- Listens to `playerProvider` (current track/book, playing) and the position stream (only to compute timestamps
  on play/seek/track change – not every tick). Activity while playing music:
  `{"type": 2, "details": title, "state": "von <artist>"/"by <artist>" (l10n), "assets": {"large_image":
  "<serverUrl>/icons/Icon-512.png", "large_text": album}, "timestamps": {"start": nowMs - positionMs, "end":
  start + durationMs}}` (strings truncated to 128 chars, min 2 chars). Audiobook: details = book title, state =
  author, large_text = chapter title if any. Paused / nothing playing / disabled → `setActivity(null)`.
  Re-send on track change, play/pause, seek (position jump > 2 s against the expected position), speed change
  (timestamps are only correct at speed 1 – at other speeds omit `end`).
- The large image must be a URL **without** the user's token (`/icons/Icon-512.png` is public).

## 4. Setting (`settings_page.dart`, section "Wiedergabe", desktop only)
`SwitchListTile` "Discord-Status anzeigen" / "Show Discord status", subtitle "Zeigt in Discord an, was du gerade
hörst" / "Shows what you're listening to on Discord", prefs key `discord_presence` (default true). If the server
has no Discord application id: subtitle "Vom Admin noch nicht eingerichtet" / "Not set up by the admin yet" and
the switch disabled.

## 5. Tests
`test/discord_rpc_test.dart`: frame encoding/decoding (opcode, little-endian length, JSON), coalescing/rate
limit with a fake clock, activity building (music, book, truncation, speed ≠ 1 without `end`), using a fake
transport (abstract the socket behind a small interface for this).
Manual check if possible: run a tiny fake Discord IPC server on a unix socket in a test (bind
`$XDG_RUNTIME_DIR/discord-ipc-0` replacement path via an injectable directory) and assert the handshake +
SET_ACTIVITY frames.

## Report
Changed/new files, tests, Windows result (works / unsupported and why), deviations.
