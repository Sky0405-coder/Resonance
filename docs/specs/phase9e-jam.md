# Phase 9e – Jam: listen together (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` for every new message, existing style,
`ruff format --line-length 120` on new/rewritten files, tests without network). Run backend tests against the
database given in the task prompt only (guards `startswith("app_test")`); the whole suite must pass. App: gen-l10n
keys in **both** ARB files, `~/flutter/bin/flutter gen-l10n`, `flutter analyze` clean, `flutter test` passes,
`JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release`, `flutter build web --release --wasm` and
`flutter build linux --release` (container build like phase 7c if host deps are missing) succeed. Do not touch
`docs/`, no release script, no upload/deploy. No database migration (Jam state lives in memory; the server runs
one uvicorn process – document this assumption in a module docstring).

## Goal
Like Spotify Jam: one user starts a Jam, others (users of the same Resonance server) join with a code or link.
Everyone sees the same queue, everyone can add songs, and every member who chooses to listen hears the same song at
the same position on their own device (phones, desktop, web). The host can let members control playback
(play/pause/skip) or keep that to themselves.

## Backend

### 1. Hub (`app/services/jam.py`, new)
- `Jam` dataclass: `code` (6 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, unique among live jams), `host_id`,
  `members: dict[user_id, Member(id, name, joined_at, connections: int)]`, `queue: list[QueueEntry(id: uuid4 str,
  track_id, added_by)]`, `index: int` (current entry, −1 = nothing), `playing: bool`, `position_ms: int` (position
  at `updated_at`), `updated_at_ms: int` (server time), `members_control: bool` (default `True`), `version: int`
  (incremented on every change).
- Current position = `position_ms + (now_ms - updated_at_ms if playing else 0)`. Every mutation first "freezes"
  the position (`position_ms = current`, `updated_at_ms = now`).
- In-memory registry `{code: Jam}` and `{user_id: code}` (a user is in at most one Jam; starting/joining another
  leaves the old one). Lock: one `asyncio.Lock` per Jam.
- Auto-advance: when the current entry's track duration (from the DB, loaded when added) has passed while playing,
  the hub moves to the next entry (`position 0`), or stops (`playing=False`, position 0 of the last entry) at the
  end. Implement with one background task per Jam that sleeps until the expected end (recomputed on every change).
- Lifetime: a Jam ends when the host leaves/ends it, or when it has had no open WebSocket connection for 10
  minutes. When the host's last connection closes, the Jam keeps running (host may reconnect) under the same rule.

### 2. REST (`app/api/jam.py`, new, prefix `/api/jam`, logged-in users)
- `POST /api/jam` body `{track_ids: list[str] = [], index: int = 0, position_ms: int = 0, playing: bool = False}`
  (the host's current queue, so a Jam starts with what is playing) → creates the Jam (leaving any previous one),
  returns `JamState` (§4). Unknown track ids are dropped. Max 500 entries.
- `GET /api/jam/current` → the caller's Jam state or 404 "Kein Jam aktiv".
- `POST /api/jam/{code}/join` (code case-insensitive) → adds the caller, returns state; unknown code → 404 "Jam
  nicht gefunden". Max 20 members → 409 "Jam ist voll".
- `POST /api/jam/leave` → leaves (host leaving ends the Jam for everyone) → 204.
- `POST /api/jam/{code}/kick/{user_id}` (host only, 403 "Nur der Host darf das") → removes the member and closes
  their sockets with a `{"type": "kicked"}` message.

### 3. WebSocket `GET /api/jam/ws?token=<token>`
- Auth with the same token rules as the stream endpoints (token query parameter; invalid → close code 4401). Not in
  a Jam → close 4404.
- On connect: send `{"type": "state", "state": JamState}`. Every change of the Jam → broadcast the full state to all
  connections of all members.
- Client → server messages (JSON): `{"type": "ping", "t": <client ms>}` → `{"type": "pong", "t": <same>, "server":
  <server ms>}` (clock sync); commands `{"type": "cmd", "cmd": <name>, ...}`:
  `play`, `pause`, `seek {position_ms}`, `next`, `previous` (position > 3 s → restart current, else previous entry),
  `jump {entry_id}`, `add {track_ids: [..], next: bool}` (`next=True` → insert after the current entry, in order),
  `remove {entry_id}`, `move {entry_id, to_index}`, `set_control {members_control: bool}` (host only).
  Playback commands (`play`, `pause`, `seek`, `next`, `previous`, `jump`) from non-hosts are rejected when
  `members_control` is false; `remove`/`move` are allowed for the host and for the member who added that entry.
  Rejections → `{"type": "error", "message": "<text>"}` (only to the sender; texts "Nur der Host darf das" /
  "Steuerung ist für Mitglieder gesperrt", translated by `Accept-Language` of the handshake like other messages).
- Ping from the server every 25 s is not needed; the client pings every 15 s (also used for clock sync).

### 4. `JamState`
`{code, host: {id, name}, members: [{id, name, is_host, online}], members_control, playing, position_ms,
server_time_ms, version, index, queue: [{entry_id, added_by: {id, name}, track: TrackOut}]}` – `TrackOut` exactly
like the library endpoints produce it for the **receiving** user (likes differ per user; build per connection).

### 5. Tests (`tests/test_jam.py`)
Create/join/leave/host-leave-ends, code uniqueness/case-insensitivity, member limit, position math with a fake clock
(monkeypatch the hub's `now_ms`), auto-advance to next / stop at end, every command incl. permission checks and
`members_control`, `add next=True` ordering, kick, WebSocket broadcast to two clients (Starlette `TestClient`
websocket or httpx-ws equivalent already available; if none is available use `starlette.testclient.TestClient`),
ping/pong, auth failure close codes, 10-minute expiry with the fake clock.

## App

### 6. Jam client (`lib/player/jam.dart`, new)
- `JamController` (Riverpod `Notifier<JamView?>`): `start()`, `join(code)`, `leave()`, `kick(userId)`,
  `setMembersControl(bool)`, `send(cmd)`, `listenHere` (bool, default true, persisted per session only).
  Uses `web_socket_channel` (add the dependency; it supports web, Android, Linux, Windows) to
  `ws(s)://<server>/api/jam/ws?token=…`; reconnect with backoff 1, 2, 5, 10 s while in a Jam; on start of the app
  `GET /api/jam/current` → reconnect automatically if the user is in a Jam.
- Clock offset: median of the last 5 ping round-trips (`offset = server - (t + rtt/2)`).
- Applying state while `listenHere`: queue/index changed → `PlayerController` loads the Jam queue (new method
  `applyJam(List<Track> tracks, int index, Duration position, bool playing)` that sets sources without shuffle,
  context `'jam:<code>'`, loop off, no crossfade while in a Jam); same entry → if |local position − expected| >
  1000 ms → seek; playing flag differs → play/pause. Expected position = `position_ms + (nowServer −
  server_time_ms)` when playing.
- While in a Jam the player's own controls (play/pause/next/previous/seek/jump, "play next", "add to queue", queue
  reorder/remove, starting any other playback like tapping a song in a list) are routed to the Jam as commands
  instead of acting locally: tapping a song in a list = `add {track_ids:[id], next:true}` followed by `jump` to it;
  playing an album/playlist = `add` all tracks with `next:true` and `jump` to the first. Shuffle/repeat buttons are
  disabled. If a command is rejected, show the error with `showError`.
- `listenHere == false` ("Nur steuern" / "Remote only"): local player stops and does not follow; the player bar and
  now-playing page still show the Jam's current track and position (computed from the state) and send commands.
- Plays are reported normally by members who listen.

### 7. UI
- Now-playing page and desktop player bar: `IconButton(Icons.groups)` "Jam". Not in a Jam → bottom sheet (use
  `showActionSheet` if it exists, else the same styling as the track menu) with "Jam starten" / "Start a Jam"
  (starts with the current queue) and "Jam beitreten" / "Join a Jam" (dialog with a 6-character code field).
  In a Jam the button is highlighted (primary colour) and opens the Jam sheet:
  - Code in large letters + "Link kopieren" / "Copy link" (`<serverUrl>/jam/<CODE>`, clipboard, `showInfo`
    "Link kopiert" / "Link copied") and the system share sheet on Android if a share plugin already exists (do not
    add one otherwise).
  - Members list (name, "Host" badge, online dot); host sees a kick `IconButton` per member.
  - Host: `SwitchListTile` "Mitglieder dürfen steuern" / "Members can control playback".
  - `SwitchListTile` "Auf diesem Gerät mithören" / "Listen on this device".
  - "Jam verlassen" / "Leave Jam" (host: "Jam beenden" / "End Jam", with confirmation).
- Queue page in a Jam: title "Jam-Warteschlange" / "Jam queue", each entry shows "Hinzugefügt von <name>" / "Added
  by <name>"; remove/reorder only where allowed.
- Player bar shows a small "Jam · <n>" chip next to the title while in a Jam.
- Web/deep link: route `/jam/:code` → join and open now-playing (also Android app links are **not** required).
- Kicked / Jam ended by host → `showInfo` "Der Jam wurde beendet" / "The Jam has ended", local playback stops,
  state cleared.
- Tests: `test/jam_test.dart` – clock offset median, expected-position math, drift decision (seek only > 1000 ms),
  command routing decision table (in Jam vs not), state parsing.

## Report
Changed/new files, backend test count, how you verified synchronisation (two emulator instances, emulator +
Linux desktop, or emulator + web; describe the measured drift), deviations.
