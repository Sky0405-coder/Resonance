# Resonance

Selbst gehosteter Musik-Streaming-Server im Spotify-Stil mit integrierter Download-Pipeline.

```
backend/   Python 3.12 · FastAPI · SQLAlchemy (async) · PostgreSQL + pgvector · Alembic
app/       Flutter-Client für Android, Linux, Windows und Web (das Web-Build wird vom Server ausgeliefert)
Dockerfile, docker-compose.yml   Deployment-Stack für Coolify (App, Postgres, gluetun/ProtonVPN, qBittorrent, Prowlarr)
```

## Roadmap

| Phase | Inhalt | Status |
|---|---|---|
| 1 | Server-Grundgerüst, Benutzer und Rollen, Einladungslinks, Bibliotheks-Scan, Streaming/Transcoding, Playlists, Likes, Verlauf, Spotify-ähnlicher Client, Admin-Dashboard | ✅ |
| 2a/b | Katalogsuche (Deezer), Anfragen mit Freigabe/Tageslimit, Download über YouTube Music (yt-dlp), Tagging über MusicBrainz (ISRC/Barcode), Einsortieren, Live-Fortschritt | ✅ |
| 2c | Bibliothek aufräumen (AcoustID), Import-Ordner, Torrents über Prowlarr + qBittorrent | ⏳ |
| 3 | Spotify-Import (OAuth und Playlist-Links, Abgleich per ISRC), abonnierte Playlists | |
| 4 | Audio-Analyse (Essentia), Song-Radio, Daily Mixes, Release Radar, temporäre Songs, Qualitäts-Upgrades | |
| 5 | Offline-Downloads, synchronisierte Lyrics (LRCLIB), Crossfade/Gapless-Feinschliff, Discord-Status, OpenSubsonic-API | |
| 6 | Usenet (SABnzbd), Jam (gemeinsames Hören), Chromecast | |

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

Das **erste registrierte Konto wird Admin**. Danach ist die Registrierung nur noch über
Einladungslinks möglich (Admin-Dashboard → Einladungen). Unter Admin-Dashboard → Server lässt sie
sich auf öffentlich umstellen.

## Deployment mit Coolify

1. Neue Ressource → *Docker Compose* → dieses Repository wählen.
2. Die Umgebungsvariablen eintragen, die oben in `docker-compose.yml` beschrieben sind (Pfade, `POSTGRES_PASSWORD`, ProtonVPN-WireGuard-Key).
3. Dem Service `resonance` die Domain zuweisen (Port 8000) und deployen.
4. Die Domain öffnen, das Admin-Konto anlegen und im Admin-Dashboard einen Bibliotheks-Scan starten.

`MUSIC_PATH` und `DOWNLOADS_PATH` sollten auf derselben Platte (HDD) liegen. Dann können fertige
Torrents per Hardlink in die Bibliothek übernommen werden und trotzdem weiter seeden. Datenbank und
Caches (`APPDATA_PATH`) gehören auf die SSD.
