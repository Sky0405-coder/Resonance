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
Dockerfile                    Image (wird per GitHub Actions als ghcr.io/sky0405-coder/resonance gebaut)
deploy/docker-compose.yml     Compose-Datei zum Selbsthosten mit dem fertigen Image
docker-compose.yml            Stack für Coolify (baut selbst; App, Postgres, gluetun/ProtonVPN, qBittorrent, Prowlarr)
```

## Installation mit Docker Compose

Das Image wird bei jedem Push auf `main` (Tag `edge`) und bei jedem Release (Tags `latest`, `1.6.17`, `1.6`) für
amd64 und arm64 gebaut, ein eigener Build ist nicht nötig.

```bash
mkdir resonance && cd resonance
curl -LO https://raw.githubusercontent.com/Sky0405-coder/Resonance/main/deploy/docker-compose.yml
curl -L -o .env https://raw.githubusercontent.com/Sky0405-coder/Resonance/main/deploy/.env.example
nano .env                                   # POSTGRES_PASSWORD, MUSIC_PATH, PUID/PGID
docker compose up -d
```

Fehlende Ordner legt der erste Start selbst an (sie gehören dann PUID/PGID). Danach `http://<server>:8765` öffnen,
das Admin-Konto anlegen und im Admin-Dashboard einen Bibliotheks-Scan starten.
Optionale Teile werden über Profile zugeschaltet (auch kombinierbar):

| Profil | Startet | Wofür |
| --- | --- | --- |
| `torrents` | gluetun (VPN mit Kill-Switch), qBittorrent, Prowlarr | Automatische Downloads von Alben, Songs und E-Books |
| `audiobooks` | Audiobookshelf | Hörbücher-Tab in der App |

```bash
docker compose --profile torrents --profile audiobooks up -d
```

Aktualisieren: `docker compose pull && docker compose up -d`. Eine feste Version statt der neuesten gibt es über
`RESONANCE_VERSION` in der `.env`.

## Empfohlene Dienste

- **Reverse Proxy mit HTTPS** (Caddy, Traefik, Nginx Proxy Manager oder ein Cloudflare Tunnel) vor Port 8765. Die
  Android-App, Chromecast und die Medien-Benachrichtigung funktionieren außerhalb des Heimnetzes nur sinnvoll über
  HTTPS.
- **Audiobookshelf** (Profil `audiobooks`) für Hörbücher. Unter Admin → Server die Adresse eintragen, unter der
  Audiobookshelf auch von außen erreichbar ist (z. B. `https://audio.example.com`).
- **Prowlarr + qBittorrent hinter einem VPN** (Profil `torrents`) für Downloads. Am besten ein Anbieter mit
  Port-Forwarding (z. B. ProtonVPN), sonst seeden Torrents kaum. In Prowlarr die Indexer anlegen, dann unter
  Admin → Server den Prowlarr-API-Key und den qBittorrent-Login eintragen.
- **Kostenlose API-Schlüssel** unter Admin → Server, alle optional:
  - AcoustID (acoustid.org/new-application): erkennt Songs am Audio-Fingerabdruck beim Import
  - Last.fm (last.fm/api): Genres und Tags für Song-Radio und Mixe
  - Discogs (discogs.com → Settings → Developers): weitere Quelle im Metadaten-Editor
  - fanart.tv: Künstlerbilder und Banner
  - Spotify Client ID/Secret (developer.spotify.com): Playlists aus Spotify importieren und synchronisieren
  - Google Books: bessere Treffer bei der E-Book-Suche
- **Backups**: der Ordner `data/postgres` (oder regelmäßig `pg_dump`) und `data/app` enthalten Konten, Playlists,
  Statistiken und Einstellungen; die Musik selbst liegt in `MUSIC_PATH`.

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
