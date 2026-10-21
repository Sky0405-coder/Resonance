<p align="center"><img src="branding/logo.svg" width="96" alt="Resonance"></p>

<h1 align="center">Resonance</h1>

<p align="center">
Selbst gehosteter Musik-Streaming-Server im Spotify-Stil – mit eigener Download-Pipeline, Apps für Android,
Desktop, Web und Fernseher.
</p>

<p align="center">
<a href="https://github.com/Sky0405-coder/Resonance/releases/latest">Neueste Version herunterladen</a>
</p>

## Funktionen

**Hören**
- Bibliothek mit Alben, Künstlern, Playlists, Likes und Verlauf; Suche über Bibliothek und Katalog
- AutoMix: Übergänge wie ein DJ – Beat- und Phrasenabgleich, Tempoangleich, Bass-Tausch, harmonisches Mixen
  (Tonarterkennung), Gesangsschutz über synchronisierte Songtexte
- Crossfade, Gapless, Equalizer, ReplayGain, Schlaftimer
- Synchronisierte Songtexte (LRCLIB), Visualizer mit Themes, Coverflow
- Autoplay, Smart Shuffle, Song-Radio, Daily Mixes, Mix der Woche, automatisch aktualisierte Charts- und
  Jahrzehnte-Playlists mit eigenen Covern
- Jam (gemeinsam hören), Offline-Downloads, Discord-Status
- Weltradio mit über 50.000 Sendern inkl. aktuellem Titel und Cover
- Hörbücher (Audiobookshelf) und E-Books

**Bibliothek pflegen**
- Anfragen mit Freigabe und Tageslimit, Downloads über YouTube Music, Torrents (Prowlarr + qBittorrent)
- Automatisches Tagging (MusicBrainz, Deezer, Apple Music, Discogs), Genres (Last.fm), Künstlerbilder und -texte
- Import-Ordner, Duplikat-Erkennung per Audio-Fingerabdruck, Qualitäts-Upgrades
- Spotify-Import und -Abgleich von Playlists

**Apps**

| Plattform | Download | Hinweis |
|---|---|---|
| Android (Handy, Android Auto, Android TV) | `…-android.apk` | aktualisiert sich selbst |
| Windows | `…-windows-setup.exe` oder portable ZIP | |
| Linux | `…-linux-x86_64.AppImage` | |
| Web | – | wird vom Server ausgeliefert |
| Samsung Smart TV (Tizen) | `…-samsung-tizen-unsigned.wgt` | muss mit eigenem Samsung-Zertifikat signiert werden, siehe [tv/tizen](tv/tizen/README.md) |

Am PC gibt es zusätzlich einen TV-/Controller-Modus (F11) für die Bedienung mit Fernbedienung oder Gamepad.
Der Server spricht außerdem OpenSubsonic, damit lassen sich auch andere Subsonic-Clients verbinden.

## Aufbau

```
backend/   Python 3.12 · FastAPI · SQLAlchemy (async) · PostgreSQL + pgvector · Alembic
app/       Flutter-Client für Android, Linux, Windows und Web
tv/tizen/  Samsung-TV-App (HTML/JavaScript, Tizen 5.5+)
Dockerfile, docker-compose.yml   Deployment-Stack (App, Postgres, gluetun/ProtonVPN, qBittorrent, Prowlarr)
```

## Installation mit Coolify

1. Neue Ressource → *Docker Compose* → dieses Repository wählen.
2. Die Umgebungsvariablen eintragen, die oben in `docker-compose.yml` beschrieben sind (Pfade, `POSTGRES_PASSWORD`,
   ProtonVPN-WireGuard-Key).
3. Dem Service `resonance` die Domain zuweisen (Port 8000) und deployen.
4. Die Domain öffnen, das Admin-Konto anlegen und im Admin-Dashboard einen Bibliotheks-Scan starten.

Das **erste registrierte Konto wird Admin**. Danach ist die Registrierung nur noch über Einladungslinks möglich
(Admin-Dashboard → Einladungen); unter Admin-Dashboard → Server lässt sie sich auf öffentlich umstellen.

`MUSIC_PATH` und `DOWNLOADS_PATH` sollten auf derselben Platte liegen, dann werden fertige Torrents per Hardlink
übernommen und seeden weiter. Datenbank und Caches (`APPDATA_PATH`) gehören auf die SSD.

## Lokale Entwicklung

```bash
# Datenbank
podman run -d --name sc-pg -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app \
  -p 55432:5432 docker.io/pgvector/pgvector:pg17

# Backend
cd backend
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/alembic upgrade head
RESONANCE_MUSIC_DIR=~/Musik RESONANCE_DATA_DIR=/tmp/resonance .venv/bin/uvicorn app.main:app --reload --port 8000
.venv/bin/pytest            # benötigt die DB "app_test" und ffmpeg

# Client
cd app
flutter run -d chrome       # oder: -d linux / Android-Gerät
flutter build web --wasm    # RESONANCE_WEB_DIR=app/build/web liefert die App unter / aus
```

Für Linux-Desktop-Builds werden zusätzlich `clang cmake ninja-build gtk3-devel mpv-devel` benötigt (Fedora/Nobara).
