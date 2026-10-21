# Resonance für Samsung Tizen TV

Eigenständige Web-App für den Samsung GQ55Q80TG (2020, Tizen 5.5 / Chromium 69).
Alle Laufzeitdateien liegen hier; Backend und Flutter-App werden nicht verändert.
HTML, CSS und ES2017-Module, ohne Framework, Build-Schritt oder npm-Abhängigkeiten.
Die Oberfläche hat 1920 × 1080 CSS-Pixel und wird bei Desktop-Vorschauen proportional skaliert.
Deutsch bei `navigator.language` mit `de`, sonst Englisch.

## TV vorbereiten

1. TV und PC ins gleiche Netzwerk bringen. Die IP-Adresse des PCs ermitteln.
2. Am TV **Apps** öffnen und mit der Fernbedienung schnell **12345** eingeben
   (bei der Smart Remote über die virtuelle Zifferntastatur).
3. **Developer mode → On**, die **PC-IP** eintragen und bestätigen.
4. TV vollständig neu starten, etwa durch langes Drücken der Power-Taste bis zum Samsung-Logo.
5. Die TV-IP aus den Netzwerkeinstellungen notieren. SDB verwendet TCP-Port **26101**.

## Samsung-Zertifikat in VS Code

Die Tizen-Erweiterung und ihre SDK-Werkzeuge einschließlich Samsung Certificate Extension
installieren. In der Befehlspalette den Certificate Manager der Tizen-Erweiterung öffnen
(bei der Tizen-TV-Erweiterung: **Tizen TV: Run Certificate Manager**).
Ein neues Profil vom Typ **Samsung → TV** anlegen, beim Samsung-Konto anmelden und
Autor- sowie Distributor-Zertifikat erstellen. Die **DUID dieses TVs** dem
Distributor-Zertifikat hinzufügen; sie wird im Device Manager des verbundenen TVs
angezeigt bzw. beim Hinzufügen eines angeschlossenen Geräts übernommen.
Installation auf dem Gerät im Device Manager erlauben, falls diese Option angeboten wird.
Profilnamen merken. Ein allgemeines Tizen-Zertifikat ersetzt kein Samsung-TV-Zertifikat.
Private Schlüssel und Passwörter bleiben im Certificate Manager und gehören nicht ins Repository.

## Paket erzeugen und installieren

Auf diesem Rechner wurden folgende Werkzeuge gefunden:

- SDB: `~/.tizen-extension-platform/server/sdktools/data/tools/sdb`
- Neue CLI: `~/.tizen-extension-platform/server/sdktools/data/tools/tizen-core/tz`
- Keine klassische `tizen`-CLI unter `…/tools/ide/bin/` oder `~/tizentv-tools/`;
  dort liegt lediglich zusätzliches SDB-Werkzeug.

`tz pack --help` bestätigt die Optionen `--type`, `--sign-profile`, `--base-pkg`,
`--out-path` und `--profiles-path`. Das Skript nutzt diese CLI zum Signieren eines
vorher erzeugten ZIPs. Eine klassische `tizen`-CLI wird ebenfalls unterstützt,
wenn installiert. Node, Python 3 und `zip` werden für die Entwicklerskripte benötigt;
der TV benötigt sie nicht. Pillow ist nur zur erneuten Icon-Erzeugung nötig.

```bash
cd tv/tizen
node check-syntax.mjs
node --test tests/*.test.mjs

# Strukturell korrektes, UNSIGNIERTES ZIP/WGT für Prüfung/Weitergabe:
./build.sh

# Mit dem eigenen Samsung-Profil signieren:
TIZEN_PROFILE='MeinSamsungTV' ./build.sh
./install.sh 192.168.1.50
```

Das Ergebnis heißt `Resonance.wgt` und wird nicht versioniert. `config.xml`,
`index.html`, `icon.png`, `css/` und `js/` stehen direkt im ZIP-Stamm.
Tests, Werkzeuge und Dokumentation werden nicht mitverpackt. Ein unsigniertes Paket
wird vom Installationsskript vor der Netzwerkverbindung abgelehnt.
Mit Profil muss das Werkzeug beide Signaturen erzeugen: `author-signature.xml`
und `signature1.xml`. Ohne gültiges Samsung-Profil mit TV-DUID ist keine Installation möglich.
Es fehlt hier kein Packaging-/Signierprogramm; ein persönliches Zertifikatsprofil
muss vom Besitzer eingerichtet und angegeben werden. Ein Gerätetest wurde nicht durchgeführt.

Werkzeugpfade können über `TIZEN_CLI=/absoluter/pfad/tz` bzw. `SDB=/absoluter/pfad/sdb`
überschrieben werden. Falls `tz` das VS-Code-Profil nicht findet:

```bash
TIZEN_CLI="$HOME/.tizen-extension-platform/server/sdktools/data/tools/tizen-core/tz" \
TIZEN_PROFILES_PATH="$HOME/.tizen-extension-platform/server/sdktools/sdk-data/profile/profiles.xml" \
TIZEN_PROFILE='MeinSamsungTV' ./build.sh
```

`install.sh` verbindet per `sdb connect <ip>:26101`, installiert mit `tz install`
(oder `tizen install`) und startet **KnodeReso1.Resonance** mit `tz run`/`tizen run`.
Nach Änderung der PC-IP den Developer-Mode-Eintrag aktualisieren und TV neu starten.
Bei Signaturfehlern DUID, Samsung-Distributor-Zertifikat und Profilzuordnung prüfen.

## Bedienung

- Pfeiltasten: räumliche Fokusnavigation, OK/Enter: auswählen. Reihen merken ihre Position.
- Zurück / Escape / Backspace: Ansicht zurück; auf Start erscheint **Beenden?**.
  Bestätigen ruft auf dem TV die Tizen-Exit-API auf.
- Play/Pause oder Leertaste: Wiedergabe umschalten; Play, Pause, Stop, vorheriger/nächster
  Titel sowie Vor-/Rückspulen werden als Samsung-Medientasten registriert.
- Gelb oder **Y**: Songtext; Blau oder **N**: „Jetzt läuft“.
- Suche und Weltradio: Bildschirmtastatur mit A–Z, Ziffern und ä/ö/ü/ß,
  Leerzeichen und Löschen. Abfrage nach 400 ms ohne Eingabe.
- Anmeldung und Server-Einstellungen haben eine zusätzliche Bildschirmtastatur mit
  Klein-/Großschreibung und Sonderzeichen. Im Desktop-Browser sind Felder auch direkt editierbar.
- Im Songtext blättern Hoch/Runter; synchronisierte Texte folgen der Audioposition.

Beim ersten Start Server-Adresse (Vorgabe `https://resonance.k-node.de`), Benutzername
und Passwort eingeben. Server und Sitzungstoken liegen in `localStorage`, das Passwort
wird nicht gespeichert. Ein Serverwechsel meldet ab. Die Einstellungen bieten Abmelden.
Die Zusatzberechtigung `tv.inputdevice` ist für die registrierten Medientasten nötig;
`productinfo` wird nicht verwendet.

## Schnittstellen und Einschränkungen

Die Verträge wurden aus `app/lib/core/api.dart`, `app/lib/core/models.dart`,
`app/lib/player/spectrum.dart` und den Backend-Routen übernommen:

- JSON-Login: `POST /api/auth/login` mit `username`, `password`, `device_name` → `token`.
  API-Abfragen verwenden `Authorization: Bearer …` und `Accept-Language`.
- Audio: `/api/tracks/{id}/stream?format=raw|mp3&bitrate=192&token=…`.
  MP3 und AAC werden roh abgespielt, andere Codecs als MP3 transcodiert.
  Das zweite Audioelement lädt den Folgetitel; echtes samplegenaues Gapless ist damit nicht garantiert.
- Cover: `/api/albums/{id}/cover?size=…&v=cover_key&token=…`, dazu Playlist-Cover,
  Künstlerbilder und das Lieblingssongs-Cover. Farbabtastung über 32 × 32 Canvas-Pixel.
- Start: `/api/home` (`recently_played`, `recently_added`, `playlists`, `most_played`).
  Suche: `/api/search?q=…`; Bibliothek: `/api/playlists`, `/api/albums`, `/api/artists`,
  `/api/me/likes/tracks`. Album/Künstler/Playlist-Details nutzen die jeweiligen ID-Routen.
- Weltradio: `/api/worldradio/stations?q=…&offset=…`, `/favorites`,
  `PUT|DELETE /favorites/{id}`, `/stations/{id}/stream?token=…`,
  `/stations/{id}/now` (Polling alle 12 Sekunden).
- Songtext: `/api/tracks/{id}/lyrics`, `lines[].time_ms`; Spektrum:
  `/api/tracks/{id}/spectrum` mit **RSP1**, 13-Byte-Header, LE-f32-fps und LE-u32-Framezahl.
  Interpolierte 24 Bänder werden gespiegelt, höchstens 30 Bilder/s, nur in „Jetzt läuft“.
- Hörereignisse: `POST /api/me/plays` mit `track_id`, `seconds_played`, `context`,
  ab 30 gehörten Sekunden oder der halben Titellänge, entsprechend Flutter.

**Backend-Grenze:** Rohdateien verwenden `FileResponse` mit HTTP Range, transcodiertes
MP3 verwendet `StreamingResponse` ohne Range-/Zeit-Seek-Schnittstelle. Deshalb kann der
Browser dort nur innerhalb seiner gemeldeten `seekable`-Bereiche spulen; andernfalls zeigt
die App einen Hinweis. Für beliebiges Spulen in transcodierter Musik wäre eine
Backend-Erweiterung nötig. Das Backend wurde nicht geändert.
Weltradio-Codecs werden vom Sender durchgereicht; nicht vom TV unterstützte Streams
können daher scheitern. Default-CORS ist `*`, die Token-Query wird serverseitig akzeptiert.
Bei eingeschränkter CORS-Konfiguration muss der Betreiber den TV-/Browser-Ursprung erlauben;
sonst scheitern Login/API und die Cover-Farbabtastung. Externe Senderbilder können auf die
Standardfarbe zurückfallen, wenn der Bildhost CORS nicht erlaubt.

## Lokal prüfen

```bash
python3 -m http.server 8765 --directory tv/tizen  # vom Repository-Stamm
# http://localhost:8765 im Browser öffnen

cd tv/tizen
node check-syntax.mjs
node --test tests/*.test.mjs
CHROMIUM=/pfad/zu/chromium node tests/browser-smoke.mjs
python3 tools/render_icon.py  # 117×117 PNG aus branding/logo.svg, mit Pillow
```

Der Kompatibilitätscheck durchsucht sämtliche Laufzeit-JS-Dateien auf die geforderten
verbotenen Sprachmerkmale, erkennt Klassenfelder und führt zusätzlich `node --check` aus.
Die Node-Tests prüfen RSP1, Navigation samt Reihen-Erinnerung, Media-URLs, Queue/Repeat/Shuffle,
Preload-Wechsel und Hörereignisse. Der Chromium-Test startet einen eigenen lokalen Server,
ein temporäres Browserprofil und ausschließlich gemockte API-/Audio-Daten. Er prüft
Anmeldung, Fernbedienung, Ansichten, Suche, Wiedergabe, Songtext und Radio-Favoriten;
er braucht keine npm-Pakete. Screenshot: `/tmp/resonance-tv-smoke.png`
(überschreibbar über `TV_SCREENSHOT`). Ein moderner Browser-Smoke-Test ersetzt keinen
Test auf dem realen Tizen-5.5-TV.

Quellen: [Samsung VS Code Extension](https://developer.samsung.com/smarttv/develop/tools/additional-tools/vscode-extension.html),
[Samsung CLI](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/command-line-interface.html),
[Samsung Remote Control](https://developer.samsung.com/smarttv/develop/guides/user-interaction/remote-control.html).
