# Phase 7c – Audio engine: audio_service, crossfade, gapless, Android Auto (Flutter app only)

Precise implementation spec. Implement exactly what is written; no extra features, settings, screens or files
beyond what is listed. Where silent, choose the simplest option matching the existing code. List any deviation
with a reason in the final report.

General rules: app only (no backend changes). All user-visible texts via gen-l10n (keys in **both**
`lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`),
`~/flutter/bin/flutter analyze` without issues, `~/flutter/bin/flutter test` passes,
`JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release`, `~/flutter/bin/flutter build web --release
--wasm` and `~/flutter/bin/flutter build linux --release` must succeed. No git commands that modify
index/HEAD/working tree, do not touch `docs/`, no release script, no upload/deploy. Existing style, comment density
and naming. Behaviour that is not mentioned (ReplayGain, play reporting, audiobooks incl. Audiobookshelf sync,
sleep timer, speed, offline files, error/restore logic in `_replacePlayback`, web `stop()` workaround) must keep
working exactly as now.

## Goal
1. Replace `just_audio_background` with our own `audio_service` handler (needed for Android Auto and for a
   two-player engine; `just_audio_background` supports one player only).
2. Crossfade between songs like Spotify (0–12 s, setting), gapless playback when crossfade is 0.
3. Android Auto: browse Resonance in the car (home, playlists, liked songs, albums, downloads) and control playback.

## 1. Dependencies (`pubspec.yaml`, `main.dart`, Android)
- Remove `just_audio_background`; add `audio_service` (latest 0.18.x) and keep `just_audio`,
  `just_audio_media_kit`. Remove every `MediaItem` import from `just_audio_background` – use `audio_service`'s
  `MediaItem` (or no tag at all on sources; see §3).
- `main.dart`: create the `ProviderContainer` first, then on **Android only** call
  `AudioService.init(builder: () => ResonanceAudioHandler(container), config: AudioServiceConfig(...))` with the
  same channel id/name, `androidNotificationOngoing: true`, `androidStopForegroundOnPause: true`,
  `androidNotificationIcon: 'drawable/ic_stat_resonance'`, `preloadArtwork: true`,
  `artDownscaleWidth: 512, artDownscaleHeight: 512`. Store the handler in a provider (e.g.
  `audioHandlerProvider`, overridden with the instance; `null` on other platforms).
- Keep `MainActivity` extending `AudioServiceActivity` (check it does), keep the service/receiver in the
  manifest. Android Auto: add `android/app/src/main/res/xml/automotive_app_desc.xml`
  (`<automotiveApp><uses name="media"/></automotiveApp>`) and in `<application>`
  `<meta-data android:name="com.google.android.gms.car.application" android:resource="@xml/automotive_app_desc"/>`.
  Also `<meta-data android:name="com.google.android.gms.car.notification.SmallIcon"
  android:resource="@drawable/ic_stat_resonance"/>`.

## 2. Engine (`lib/player/engine.dart`, new)
`class PlaybackEngine` owns **two** `AudioPlayer`s and exposes the API `PlayerController` currently uses on its
single `player`, always referring to the **active** player:
`playerStateStream`, `currentIndexStream`, `positionStream`, `durationStream`, `loopModeStream`, `playing`,
`processingState`, `position`, `duration`, `currentIndex`, `loopMode`, `hasPrevious`, `audioSources` (spec list,
see below), `play()`, `pause()`, `stop()`, `seek(Duration, {int? index})`, `seekToNext()`, `seekToPrevious()`,
`setLoopMode`, `setSpeed`, `setVolume` (the target volume of the active track, i.e. user volume × ReplayGain),
`insert(int, …)`, `removeAt(int)`, `setSources(...)`, `dispose()`. Streams are broadcast streams that forward the
active player's events and re-emit the current value when the active player changes (no stale values from the
inactive one).
- **Sources**: the engine receives a list of source *factories* (`AudioSource Function()`), because one
  `AudioSource` instance cannot be attached to two players. Both players get the full list built from the same
  factories (`setAudioSources(..., preload: <true only for the active one>)`); every queue edit is applied to both.
- **Shuffle moves out of just_audio**: players always run with `shuffleModeEnabled = false`. `PlayerController`
  implements shuffle itself: remember the original order (`_unshuffled`), build the new queue as `[current] + shuffled(rest)` with index 0, reload sources while
  continuing the current track without interruption (on the active player, replace sources around the current
  item: remove all others and insert the new ones – do not reload the current item). Disabling restores the original
  order with the current track at its original index, again without interrupting it. `playTracks` with shuffle on
  starts at the chosen (or random) track and shuffles the rest as above. Queue page
  (`now_playing_page.dart` currently uses `ctrl.player.effectiveIndices`) shows the queue in list order.
  `PlayerView.shuffle` stays the source of truth for the UI.
- **Crossfade** (`crossfadeSeconds`, 0–12, from the setting): when > 0, music is playing (not an audiobook),
  loop mode is not `one`, and there is a next item (or loop `all`), then at
  `position >= duration - crossfade` of the active track (only if the track is longer than 2 × crossfade):
  the inactive player seeks to the next index at 0 and plays with volume 0; over the crossfade the active volume
  goes linearly target→0 and the inactive 0→its target (its own ReplayGain factor × user volume; ask the controller
  via a callback for the gain of an index), in 50 ms steps. When done: old player `pause()`s, the roles swap, the
  streams switch. The controller sees a normal `currentIndex` change (play reporting and gain logic run as usual,
  but must not reset the new player's volume during the fade).
  - User actions during a fade (pause, seek, next/previous, jumpTo, queue replacement, stop): first finish the
    fade instantly (swap now, old player paused, new player at full target volume), then apply the action.
    Pause during a fade = pause and finish.
  - Manual `seekToNext`/`jumpTo` never crossfade (instant switch on the active player, like now).
  - With crossfade 0 the second player stays idle: playback is the active player's playlist exactly as today
    (gapless on Android/ExoPlayer and web).
- Speed: applied to both players.

## 3. Controller (`lib/player/player.dart`)
- Use the engine instead of `AudioPlayer` everywhere (`player` field → `engine`); keep `PlayerView`.
- `positionProvider`/`durationProvider` read from the engine streams.
- `crossfadeSeconds` loaded from prefs key `crossfade_seconds` (int, default 0) like `normalize` and
  `setCrossfade(int)`.
- Sources: keep `_source(Track)` logic (offline file vs. stream URL) but as factories; tags: the `MediaItem` tags
  are no longer needed by a background plugin – drop them or keep `audio_service` MediaItems in the controller's
  own map, whatever is simpler.

## 4. Audio handler (`lib/player/audio_handler.dart`, new, Android)
`class ResonanceAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler`:
- Publishes `playbackState` (controls: previous, play/pause, next; `systemActions` seek, seekForward/Backward
  only for audiobooks; `androidCompactActionIndices: [0, 1, 2]`; processing state mapped from just_audio;
  `updatePosition`, `bufferedPosition`, `speed`, `queueIndex`, `shuffleMode`, `repeatMode`), `mediaItem`
  (current track: id, title, artistCredit, album, duration, `artUri` = offline cover file or
  `api.coverUrl(albumId, size: 600)`; for audiobooks the same data the current `MediaItem` tags contain) and
  `queue`, derived from `playerProvider` state + engine streams. Update positions on state changes, not every
  position tick.
- Forwards `play`, `pause`, `stop`, `seek`, `skipToNext`, `skipToPrevious` (controller's Spotify-like
  previous), `skipToQueueItem`, `setShuffleMode`, `setRepeatMode`, `fastForward`/`rewind` (books: ±30 s/−15 s like
  the existing book buttons, if they exist; else ±30 s) to the controller.
- Notification + lock screen must look and behave like now (title, artist, cover, controls).

## 5. Android Auto (in the handler)
Browse tree via `getChildren(parentMediaId, [options])` / `getMediaItem`, ids are strings:
- `root` (`AudioService.browsableRootId`) → browsable folders: `home` "Startseite"/"Home",
  `playlists` "Playlists", `liked` "Lieblingssongs"/"Liked Songs", `albums` "Alben"/"Albums",
  `downloads` "Heruntergeladen"/"Downloaded" (only if there are offline collections). Use
  `AudioService.recentRootId` → the current queue's collection is not required; return `[]`.
- `home` → the user's generated mixes/home sections that the home page shows as playlists (reuse the existing
  providers/API calls; first 20 playable collections) as browsable items.
- `playlists` → user's playlists (browsable, `playlist:<id>`), `liked` → liked tracks (playable,
  `track:liked:<trackId>`), `albums` → saved albums (browsable `album:<id>`), `downloads` → offline collections.
- `playlist:<id>` / `album:<id>` / mix ids → their tracks as playable items `track:<collectionKind>:<collectionId>:<trackId>`.
- Every item has title, subtitle (artist / owner) and `artUri` (album cover / playlist cover URL the app already
  uses; for offline collections the local file). Use the same API client and auth token as the app (read through
  the `ProviderContainer`). Offline mode: if requests fail, fall back to offline collections only.
- `playFromMediaId(id)`: load the collection's track list and call `playTracks(list, index: <trackIndex>,
  context: <same context string the app uses for that collection>)`.
- `playFromSearch(query)` and `search(query)`: use the existing library search; play the best track result with
  the remaining track results as queue; empty query → resume / play liked songs shuffled.
- Error/empty: return `[]`, never throw into audio_service.
- Content style hints: root extras `{'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
  'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1}` (grid for folders/collections, list for tracks).

## 6. Settings (`settings_page.dart`, section "Wiedergabe")
Below the normalize switch: `ListTile` "Crossfade" / "Crossfade" with subtitle "Aus" / "Off" or "{n} s" and a
`Slider` (0–12, divisions 12) below it (like Spotify); stored in prefs `crossfade_seconds`, applied immediately
via `setCrossfade`. Loaded on startup where `normalize` is loaded.

## 7. Tests
`test/engine_test.dart`: the pure parts – fade volume curve (given t, crossfade, gains), the decision "start
fade now?" (book, loop one, last item without loop, short track, crossfade 0), shuffle/unshuffle queue
transformation (current track kept, original order restored). Put these in small pure functions to make them
testable.

## Report
Changed/new files, how you verified (analyze, test, builds; if you can, start the APK in the emulator
`~/Android/Sdk/emulator/emulator -avd resonance -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect`
and check that playback + notification work), deviations.
