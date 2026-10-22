"""Translate server-owned messages at the HTTP boundary; stored text stays German."""

import re

from fastapi import Request

_EXACT: dict[str, str] = {
    "Podcast nicht gefunden": "Podcast not found",
    "Episode nicht gefunden": "Episode not found",
    "Podcast-Suche nicht erreichbar": "Podcast search unavailable",
    "Podcast-Kategorie nicht gefunden": "Podcast category not found",
    "Podcast-Charts nicht erreichbar": "Podcast charts unavailable",
    "Podcast-Feed nicht erreichbar oder ungültig": "Podcast feed unavailable or invalid",
    "Bücher sind nicht aktiviert": "Books are not enabled",
    "Automatische Downloads sind deaktiviert": "Automatic downloads are disabled",
    "Das Buch ist schon in der Bibliothek": "The book is already in the library",
    "Buchkatalog nicht erreichbar": "Book catalog is unavailable",
    "Keine gültige Buchdatei": "Invalid book file",
    "Diese Datei ist schon in der Bibliothek": "This file is already in the library",
    "Kein passender Download gefunden": "No matching download found",
    "Falsche Sprache": "Wrong language",
    "Keine Buchdatei im Download": "No book file in the download",
    "Format wird nicht unterstützt": "Format is not supported",
    "Datei ist zu groß": "File is too large",
    "Download fehlgeschlagen": "Download failed",
    "Registrierung nur in Resonance": "Registration is only available in Resonance",
    "Anfrage läuft noch": "Request is still running",
    "Keine Berechtigung": "Permission denied",
    "Buch nicht gefunden": "Book not found",
    "Kein Schlüssel eingetragen": "No key configured",
    "Bibliothek nicht beschreibbar": "Library is not writable",
    "Neu hinzugefügt": "Recently added",
    "Autoren": "Authors",
    "Serien": "Series",
    "Meine Anfragen": "My requests",
    "Bücher": "Books",
    "Buch": "Book",

    "Radiosender-Verzeichnis nicht erreichbar": "Radio station directory unavailable",
    "Sender nicht gefunden": "Station not found",
    "Sender nicht erreichbar": "Station unavailable",
    "Not authenticated": "Not authenticated",
    "Invalid or expired session": "Invalid or expired session",
    "Admin only": "Admin only",
    "Unknown entry": "Unknown entry",
    "Unknown track id": "Unknown track id",
    "Entry not found": "Entry not found",
    "Track not found": "Track not found",
    "User not found": "User not found",
    "Artist not found": "Artist not found",
    "Album not found": "Album not found",
    "No cover": "No cover",
    "File missing on disk": "File missing on disk",
    "Nicht gefunden": "Not found",
    "Einladungslink ist ungültig oder abgelaufen": "Invitation link is invalid or has expired",
    "Registrierung nur mit Einladungslink möglich": "An invitation link is required to register",
    "Benutzername ist bereits vergeben": "Username is already taken",
    "Benutzername oder Passwort falsch": "Incorrect username or password",
    "Konto ist deaktiviert": "Account is disabled",
    "Aktuelles Passwort ist falsch": "Current password is incorrect",
    "Es muss mindestens ein aktiver Admin bleiben": "At least one active admin must remain",
    "Du kannst dich nicht selbst löschen": "You cannot delete your own account",
    "Playlist nicht gefunden": "Playlist not found",
    "Nur eigene Playlists können ein Cover haben": "Only user playlists can have a cover",
    "Nicht deine Playlist": "This is not your playlist",
    "Radios und Mixe können nicht geteilt werden": "Radios and mixes cannot be shared",
    "Unbekannter Nutzer": "Unknown user",
    "Keine Radio-Playlist": "This is not a radio playlist",
    "Mixe werden automatisch erstellt": "Mixes are created automatically",
    "Mix der Woche": "Discover Weekly",
    "Neue Songs für dich – jeden Montag neu": "New songs for you – fresh every Monday",
    "Kuratiert von Apple Music – wöchentlich aktualisiert": "Curated by Apple Music – updated weekly",
    "Kuratiert von Apple Music – täglich aktualisiert": "Curated by Apple Music – updated daily",
    "Deutschrap 100": "German Rap 100",
    "Album nicht im Katalog gefunden": "Album not found in the catalog",
    "Nicht im Katalog gefunden": "Not found in the catalog",
    "Katalog nicht erreichbar": "Catalog is unavailable",
    "Song nicht gefunden": "Song not found",
    "Titel nicht gefunden": "Track not found",
    "Album nicht gefunden": "Album not found",
    "Anfrage nicht gefunden": "Request not found",
    "Nur für Admins": "Admin only",
    "Anfrage wartet nicht auf Freigabe": "Request is not awaiting approval",
    "Aktive Anfrage kann nicht gelöscht werden": "An active request cannot be deleted",
    "Keine App-Version hochgeladen": "No app version uploaded",
    "Datei zu groß": "File is too large",
    "Keine gültige APK-Datei": "Invalid APK file",
    "Audiodatei nicht lesbar": "Audio file cannot be read",
    "Audiodatei nicht importierbar": "Audio file cannot be imported",
    "Datei nicht gefunden": "File not found",
    "Kein gültiges Bild": "Invalid image",
    "Kein AcoustID-Schlüssel eingetragen": "No AcoustID key configured",
    "Kein Last.fm-Schlüssel eingetragen": "No Last.fm key configured",
    "Kein Discogs-Token eingetragen": "No Discogs token configured",
    "Discogs nicht erreichbar": "Discogs is unavailable",
    "Genres konnten nicht ergänzt werden": "Genres could not be filled",
    "Kein Künstlerbild": "No artist image",
    "AcoustID-Anfrage fehlgeschlagen": "AcoustID request failed",
    "AcoustID nicht erreichbar": "AcoustID is unavailable",
    "Unvollständige Angaben": "Incomplete details",
    "Song nicht auf dieser Veröffentlichung": "Song is not on this release",
    "Nicht bei MusicBrainz gefunden": "Not found on MusicBrainz",
    "MusicBrainz nicht erreichbar": "MusicBrainz is unavailable",
    "Bildquelle nicht erlaubt": "Image source is not allowed",
    "Bildquelle nicht erreichbar": "Image source is unavailable",
    "Bild zu groß": "Image is too large",
    "Song wurde gelöscht": "Song was deleted",
    "Nicht im Torrent enthalten": "Not included in the torrent",
    "Torrents sind deaktiviert": "Torrents are disabled",
    "Torrent-Downloadadresse fehlt": "Torrent download address is missing",
    "Zu viele Torrent-Weiterleitungen": "Too many torrent redirects",
    "Die Discord-Anwendungs-ID darf nur aus bis zu 24 Ziffern bestehen": "The Discord application ID may only consist of up to 24 digits",
    "Keine Download-Quelle aktiviert": "No download source enabled",
    "Keine andere Version gefunden": "No alternative version found",
    "Keine passende Quelle gefunden": "No matching source found",
    "Kein Jam aktiv": "No active Jam",
    "Jam nicht gefunden": "Jam not found",
    "Jam ist voll": "The Jam is full",
    "Nur der Host darf das": "Only the host can do that",
    "Steuerung ist für Mitglieder gesperrt": "Playback control is locked for members",
    "Nicht in diesem Jam": "Not in this Jam",
    "Mitglied nicht gefunden": "Member not found",
    "Song nicht in der Warteschlange": "Song is not in the queue",
    "Unbekannter Befehl": "Unknown command",
    "YouTube blockiert gerade – neuer Versuch in 30 Minuten": "YouTube is blocking downloads right now – retrying in 30 minutes",
    "Abgebrochen": "Cancelled",
    "Kein gültiger YouTube-Link": "Invalid YouTube link",
    "Kein gültiger YouTube- oder SoundCloud-Link": "Invalid YouTube or SoundCloud link",
    "Nur fehlgeschlagene Songs können eine eigene Quelle bekommen": "Only failed songs can get a custom source",
    "Kein passender Torrent gefunden": "No matching torrent found",
    "Torrent-Download fehlgeschlagen": "Torrent download failed",
    "Torrent verschwunden": "Torrent disappeared",
    "Torrent ohne Fortschritt": "Torrent is not making progress",
    "qBittorrent-Anmeldung fehlgeschlagen": "qBittorrent login failed",
    "qBittorrent nicht erreichbar": "qBittorrent is unavailable",
    "Ungültige qBittorrent-Antwort": "Invalid qBittorrent response",
    "Prowlarr nicht erreichbar oder ungültige Antwort": "Prowlarr is unavailable or returned an invalid response",
    "Es läuft bereits ein Import": "An import is already running",
    "Der Import-Ordner ist leer": "The import folder is empty",
    "Import läuft nicht": "Import is not running",
    "Durch Neustart abgebrochen": "Cancelled by a server restart",
    "Import fehlgeschlagen": "Import failed",
    "Import nicht gefunden": "Import not found",
    "Zielpfad gehört bereits zu einem anderen Bibliothekstitel": "Target path already belongs to another library track",
    "Kein AcoustID-Schlüssel – Erkennung nur über vorhandene Tags": "No AcoustID key – identifying using existing tags only",
    "Ungültiges ASF-Cover": "Invalid ASF cover",
    "Ungültige Adresse": "Invalid address",
    "Keine Veröffentlichung gefunden": "No release found",
    "Keine Aufnahme auf der Veröffentlichung gefunden": "No recording found on this release",
    "Kein Spotify-Konto verbunden": "No Spotify account connected",
    "Spotify ist auf diesem Server nicht eingerichtet": "Spotify is not configured on this server",
    "Ungültiger oder abgelaufener Status": "Invalid or expired state",
    "Autorisierungscode fehlt": "Authorization code is missing",
    "Spotify ist verbunden. Du kannst dieses Fenster schließen und zu Resonance zurückkehren.": "Spotify is connected. You can close this window and return to Resonance.",
    "Nichts ausgewählt": "Nothing selected",
    "Spotify nicht erreichbar": "Spotify is unavailable",
    "Spotify-Verbindung abgelaufen – bitte neu verbinden": "Spotify connection expired – please reconnect",
    "Spotify-Limit erreicht – bitte später erneut versuchen": "Spotify rate limit reached – please try again later",
    "Playlist nicht gefunden oder privat": "Playlist not found or private",
    "Tageslimit erreicht – weitere fehlende Songs wurden nicht angefragt": "Daily limit reached – no more missing songs were requested",
    "Lieblingssongs": "Liked Songs",
    "Von Spotify importiert": "Imported from Spotify",
    "Von Apple Music importiert": "Imported from Apple Music",
    "Ungültige Song-ID": "Invalid song id",
    "Apple Music nicht erreichbar": "Apple Music is unavailable",
    "Aus Resonance exportiert": "Exported from Resonance",
    "Spotify gibt die Songs dieser Playlist nicht frei": "Spotify does not provide the songs in this playlist",
    "Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden": "Spotify write permissions are missing – please reconnect Spotify in settings",
    "Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen": "Spotify playlist not found – please create the link again",
    "Abgleich fehlgeschlagen": "Sync failed",
    "Diese Playlist kann nicht mit Spotify verknüpft werden": "This playlist cannot be linked to Spotify",
    "Playlist ist bereits mit Spotify verknüpft": "Playlist is already linked to Spotify",
    "Spotify-Playlist nicht verfügbar": "Spotify playlist unavailable",
    "Nicht mit Spotify verknüpft": "Not linked to Spotify",
    "Keine Adresse eingetragen": "No address configured",
    "Audiobookshelf ist nicht eingerichtet": "Audiobookshelf is not configured",
    "Kein Audiobookshelf-Konto verbunden": "No Audiobookshelf account connected",
    "Audiobookshelf nicht erreichbar": "Audiobookshelf is unavailable",
    "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden": "Audiobookshelf session expired – please sign in again",
    "Widersprüchliche Authentifizierung": "Conflicting authentication",
    "Ungültiger API-Schlüssel": "Invalid API key",
    "Unbekannter Albumlistentyp": "Unknown album list type",
    "Parameter fehlt: id oder albumId": "Missing parameter: id or albumId",
    "Ungültiger Songindex": "Invalid song index",
    "Titel oder Album nicht gefunden": "Track or album not found",
    "Cover nicht gefunden": "Cover not found",
    "Audiodatei nicht gefunden": "Audio file not found",
    "Audioformat nicht unterstützt": "Audio format is not supported",
    "Nicht berechtigt": "Permission denied",
    "Benutzer nicht gefunden": "User not found",
    "Künstler nicht gefunden": "Artist not found",
    "Nicht unterstützt": "Not supported",
    "Ungültige Anfrage": "Invalid request",
    "Ungültige Parameter": "Invalid parameters",
    "Interner Fehler": "Internal error",
    "Neu für dich": "New for you",
    "Songs aus deiner Bibliothek, die du noch nicht gehört hast": "Songs in your library you haven't heard yet",
    "Lange nicht gehört": "Haven't heard in a while",
    "Deine Favoriten": "Favourites Mix",
    "Top 100 Deutschland": "Top 100 Germany",
    "Die aktuellen Charts – täglich aktualisiert": "The current charts – updated daily",
    "Auf Repeat": "On Repeat",
    "Deine meistgehörten Songs der letzten 30 Tage": "Your most played songs of the last 30 days",
    "Deine meistgehörten und gelikten Songs": "Your most played and liked songs",
    "Neuheiten-Mix": "New Music Mix",
    "Neue Songs deiner Lieblingskünstler und frisch in der Bibliothek": "New songs from your favourite artists and fresh in the library",
    "Songs, die du lange nicht gehört hast": "Songs you haven't heard in a while",
    "Vollständiger Scan": "Full scan",
    "Schneller Scan": "Quick scan",
}

_PATTERNS: list[tuple[re.Pattern, str]] = [
    (
        re.compile(r"Tageslimit erreicht \((?P<count>\d+) von (?P<limit>\d+) Songs in 24 Stunden\)"),
        r"Daily limit reached (\g<count> of \g<limit> songs in 24 hours)",
    ),
    (re.compile(r"Download fehlgeschlagen: (?P<error>.*)"), r"Download failed: \g<error>"),
    (re.compile(r"Import fehlgeschlagen: (?P<error>.*)"), r"Import failed: \g<error>"),
    (re.compile(r"Ungültiger Spotify-Link: (?P<link>.*)"), r"Invalid Spotify link: \g<link>"),
    (re.compile(r"Spotify-Fehler \(HTTP (?P<status>\d+)\)"), r"Spotify error (HTTP \g<status>)"),
    (re.compile(r"Audiobookshelf-Fehler \(HTTP (?P<status>\d+)\)"), r"Audiobookshelf error (HTTP \g<status>)"),
    (
        re.compile(r"Prowlarr-Anfrage fehlgeschlagen \(HTTP (?P<status>\d+)\)"),
        r"Prowlarr request failed (HTTP \g<status>)",
    ),
    (
        re.compile(r"qBittorrent-Anfrage fehlgeschlagen \(HTTP (?P<status>\d+)\)"),
        r"qBittorrent request failed (HTTP \g<status>)",
    ),
    (re.compile(r"(?P<id>.+): Playlist nicht verfügbar"), r"\g<id>: Playlist unavailable"),
    (
        re.compile(r"„(?P<name>.*)“: Spotify gibt die Songs dieser Playlist nicht frei"),
        r"“\g<name>”: Spotify does not provide the songs in this playlist",
    ),
    (
        re.compile(
            r"„(?P<name>.*)“: "
            + re.escape(
                "nur die ersten 100 Songs übernommen – fremde Playlists gibt Spotify nicht vollständig heraus. Tipp: In Spotify alle Songs markieren (Strg+A), zu einer neuen eigenen Playlist hinzufügen und diese mit verbundenem Spotify-Konto unter „Deine Playlists“ importieren"
            )
        ),
        r"“\g<name>”: only the first 100 songs were imported – Spotify does not hand out other people's playlists in full. Tip: in Spotify select all songs (Ctrl+A), add them to a new playlist of your own and import that one with your connected Spotify account under “Your playlists”",
    ),
    (re.compile(r"Parameter fehlt: (?P<name>.*)"), r"Missing parameter: \g<name>"),
    (re.compile(r"Ungültiger Parameter: (?P<name>.*)"), r"Invalid parameter: \g<name>"),
    (re.compile(r"(?P<artists>.+) und mehr"), r"\g<artists> and more"),
    (re.compile(r"Das Beste aus den (?P<decade>\d+)ern in deiner Bibliothek"), r"The best of the \g<decade>s in your library"),
    (re.compile(r"(?P<decade>\d+)er Mix"), r"\g<decade>s Mix"),
    (
        re.compile(r"(?P<genre>.+) aus den (?P<decade>\d+)ern in deiner Bibliothek"),
        r"\g<decade>s \g<genre> in your library",
    ),
    (re.compile(r"(?P<decade>\d{2})er Deutschrap"), r"\g<decade>s German Rap"),
    (re.compile(r"(?P<decade>\d{2})er Deutschpop"), r"\g<decade>s German Pop"),
    (re.compile(r"(?P<decade>[0-9]0|20[0-2]0)er (?P<genre>.+)"), r"\g<decade>s \g<genre>"),
    (re.compile(r"(?P<artist>.+) und ähnliche Künstler"), r"\g<artist> and similar artists"),
    (re.compile(r"Das Beste aus (?P<genre>.+) in deiner Bibliothek"), r"The best of \g<genre> in your library"),
    (re.compile(r"Durchsuche (?P<root>.*) …"), r"Scanning \g<root> …"),
    (re.compile(r"(?P<done>\d+)/(?P<total>\d+) Dateien verarbeitet"), r"\g<done>/\g<total> files processed"),
    (
        re.compile(r"(?P<total>\d+) Dateien, (?P<changed>\d+) neu/geändert, (?P<removed>\d+) entfernt"),
        r"\g<total> files, \g<changed> new/changed, \g<removed> removed",
    ),
    (re.compile(r"(?P<prefix>.*Value error, )Ungültige Adresse(?P<suffix>.*)"), r"\g<prefix>Invalid address\g<suffix>"),
]

# Spotify embeds its own errors after a playlist id; keep that id untouched.
_PATTERNS.extend([
    (re.compile(r"Tageslimit erreicht \((?P<count>\d+) von (?P<limit>\d+) Büchern in 24 Stunden\)"), r"Daily limit reached (\g<count> of \g<limit> books in 24 hours)"),
    (re.compile(r"(?P<count>\d+) Bücher"), r"\g<count> books"),
])

_PATTERNS.extend(
    (re.compile(r"(?P<id>[A-Za-z0-9.-]+): " + re.escape(message)), r"\g<id>: " + english)
    for message, english in _EXACT.items()
    if message in {"Spotify nicht erreichbar", "Playlist nicht gefunden oder privat", "Apple Music nicht erreichbar"}
)
_PATTERNS.extend(
    (re.compile("Verbindung fehlgeschlagen: " + re.escape(message)), "Connection failed: " + english)
    for message, english in _EXACT.items()
    if message
    in {
        "Spotify nicht erreichbar",
        "Spotify-Verbindung abgelaufen – bitte neu verbinden",
        "Spotify-Limit erreicht – bitte später erneut versuchen",
        "Ungültiger oder abgelaufener Status",
        "Autorisierungscode fehlt",
    }
)
_PATTERNS.extend(
    [
        (
            re.compile(r"(?P<id>[A-Za-z0-9]+): Spotify-Fehler \(HTTP (?P<status>\d+)\)"),
            r"\g<id>: Spotify error (HTTP \g<status>)",
        ),
        (
            re.compile(r"Verbindung fehlgeschlagen: Spotify-Fehler \(HTTP (?P<status>\d+)\)"),
            r"Connection failed: Spotify error (HTTP \g<status>)",
        ),
        (re.compile(r"Verbindung fehlgeschlagen: (?P<error>.*)"), r"Connection failed: \g<error>"),
    ]
)


def language(request: Request) -> str:
    header = request.headers.get("accept-language")
    if header is None:
        return "de"
    return "de" if header.split(",", 1)[0].strip().lower().startswith("de") else "en"


def translate(message: str, lang: str) -> str:
    if lang == "de":
        return message
    if "\n" in message:
        return "\n".join(translate(line, lang) for line in message.split("\n"))
    if message in _EXACT:
        return _EXACT[message]
    for pattern, replacement in _PATTERNS:
        match = pattern.fullmatch(message)
        if match is not None:
            return match.expand(replacement)
    return message
