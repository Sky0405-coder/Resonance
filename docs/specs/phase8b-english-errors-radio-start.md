# Phase 8b – English server messages + instant radio start (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network). Run backend tests against the database given in the task prompt only (guards `startswith("app_test")`);
the whole existing suite must still pass. App: all user-visible texts via gen-l10n (keys in **both**
`lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`),
`~/flutter/bin/flutter analyze` without issues, `~/flutter/bin/flutter test` passes,
`JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release` and
`~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch `docs/`, do not run the release
script, do not upload/deploy anything.

## Part A – English server messages

The app is German/English (gen-l10n), but every server message is German. The app already sends
`Accept-Language: <de|en>` (`lib/core/api.dart`).

### 1. Translation module (`app/i18n.py`, new)
- `def language(request: Request) -> str`: `"de"` if the first language in `Accept-Language` starts with `de`,
  `"en"` for anything else **present**; no header → `"de"` (keeps existing tests and old clients).
- `def translate(message: str, lang: str) -> str`: `lang == "de"` → unchanged. Else: exact lookup in a dict
  `_EXACT: dict[str, str]`, then a list `_PATTERNS: list[tuple[re.Pattern, str]]` for messages with values
  (`re.fullmatch`, replacement with `\g<name>` groups), else the original. Multi-line messages (Spotify import
  `message` joins lines with `\n`) are translated line by line.
- Fill `_EXACT`/`_PATTERNS` with **every** German user-facing message of the backend: all `HTTPException(...,
  "<text>")` / `detail=` strings, f-string details (as patterns), `DownloadItem.error` values set in
  `services/downloads.py` (incl. `"Download fehlgeschlagen: {e}"` → `"Download failed: {e}"` keeping the
  exception text), `torrent_error` values, `ImportFile`/`ImportBatch` error/status messages shown in the app,
  Spotify import messages (`_message(...)` and `batch.message`), Subsonic error messages, radio/mix messages,
  validation messages the code raises itself. Find them with grep over `app/` (e.g. `HTTPException(`,
  `error=`, `_message(`, `message=`, `torrent_error`). Use natural English in the style of the app's English ARB.
- Unit test (`tests/test_i18n.py`): every `_EXACT` key and every pattern is exercised; a grep-based test
  collects all string literals passed as the second argument / `detail=` of `HTTPException` in `app/**/*.py` and
  asserts each literal (non-f-string) has an `_EXACT` entry (so new messages cannot be forgotten).

### 2. Where translation happens
- Exception handler for `HTTPException` (and `StarletteHTTPException`) in `app/main.py`: translate
  `exc.detail` when it is a `str`, keep status code and headers. Do not change `RequestValidationError` output.
- Output schemas carrying stored messages translate on the way out, using the request's language:
  download items' `error`, requests' `torrent_error`, Spotify imports' `message` and `missing_tracks[].source`
  is **not** translated (it is a playlist name except "Lieblingssongs" → translate only that value), import
  batch/file errors (`api/imports.py`). Do it in the endpoint functions (pass `lang`), not in the ORM.
- Subsonic (`api/subsonic.py`): error messages translated by the same rule (Subsonic clients usually send no
  `Accept-Language` → German stays default; that is fine).

## Part B – Instant radio start (app)

Today `startRadio` (`lib/ui/widgets/track_list.dart`) waits for `POST /api/radio` (several catalog lookups,
seconds) before anything plays, and songs that finish downloading later never reach the playing queue.

### 3. Start immediately
- Song radio (`seedType == 'track'`) started from a library track: before calling the API, play the seed track
  immediately with `playTracks([seed], context: 'radio:pending')` (the menu has the `Track`; change the
  signature to `startRadio(context, ref, 'track', t.id, seed: t)` and pass it where available – track menu,
  now-playing menu). Album/artist radio: unchanged start (no seed track to play).
- When the API returns: if the user has not started something else meanwhile (the controller's context is still
  `'radio:pending'` and the current track is the seed), replace the **upcoming** queue without interrupting the
  seed: new controller method `Future<void> replaceUpcoming(List<Track> tracks, {required String context})` –
  queue becomes `[current] + tracks without the seed track id`, context becomes `context`, the current item keeps
  playing (use the engine's `setSources(..., preserveCurrent: true)`), shuffle state respected (if shuffle is on,
  the upcoming part is shuffled and `_unshuffled` = unshuffled order). Otherwise (user moved on) do not touch
  playback. Then navigate to the radio playlist like now.
- API error: keep the seed playing, show the error like now.

### 4. Songs that finish downloading are appended
- While the controller's context is `playlist:<id>` of a radio playlist (the playlist model already knows if it is
  a radio – use that flag; if it does not, use the `radio` fields `PlaylistOut` has), refresh that playlist every
  20 s (and immediately when the download summary's running count decreases) and append entries whose track is
  not yet in the queue to the end of the queue (`addToQueue` semantics, no interruption, no duplicates). Stop
  when the context changes, when the playlist has no pending downloads anymore (`requested`/pending count from
  the API; if the API has no such field, stop after 30 minutes), or on app pause/background is irrelevant (timer
  keeps running only while the app process lives).
- Implement this in a small class in `lib/player/` (e.g. `radio_follow.dart`) owned by the controller or a
  provider, so it can be unit-tested with fakes.

### 5. Tests
- `test/radio_follow_test.dart`: append only new tracks, no duplicates, stops on context change, stops when no
  pending downloads.
- `test/engine_test.dart` (extend): `replaceUpcoming` queue transformation (pure function) with and without
  shuffle.

## Report
Changed/new files, backend test count, number of translated messages, how you verified the app, deviations.
