import ast
import json
import re
import uuid
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI, HTTPException, Request
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.db import Base, SessionLocal, engine
from app.i18n import _EXACT, _PATTERNS, language, translate
from app.main import http_exception
from app.models import (
    DownloadItem,
    DownloadRequest,
    ImportBatch,
    ImportFile,
    Job,
    Playlist,
    SpotifyImport,
)
from tests.conftest import auth, register


@pytest.mark.parametrize(
    "header,expected",
    [
        (None, "de"),
        ("de", "de"),
        ("de-DE,en;q=0.8", "de"),
        (" DE-at ", "de"),
        ("en,de;q=0.9", "en"),
        ("fr,de", "en"),
        ("", "en"),
        ("*", "en"),
    ],
)
def test_language(header: str | None, expected: str) -> None:
    headers = [] if header is None else [(b"accept-language", header.encode())]
    assert language(Request({"type": "http", "headers": headers})) == expected


@pytest.mark.parametrize("message,english", _EXACT.items())
def test_exact(message: str, english: str) -> None:
    assert translate(message, "en") == english
    assert translate(message, "de") == message


PATTERN_CASES = [
    ("Tageslimit erreicht (3 von 10 Songs in 24 Stunden)", "Daily limit reached (3 of 10 songs in 24 hours)"),
    ("Download fehlgeschlagen: Fehler: \\g<name>", "Download failed: Fehler: \\g<name>"),
    ("Import fehlgeschlagen: broken file", "Import failed: broken file"),
    ("Ungültiger Spotify-Link: https://example.test/a?x=1", "Invalid Spotify link: https://example.test/a?x=1"),
    ("Spotify-Fehler (HTTP 403)", "Spotify error (HTTP 403)"),
    ("Audiobookshelf-Fehler (HTTP 503)", "Audiobookshelf error (HTTP 503)"),
    ("Prowlarr-Anfrage fehlgeschlagen (HTTP 401)", "Prowlarr request failed (HTTP 401)"),
    ("qBittorrent-Anfrage fehlgeschlagen (HTTP 500)", "qBittorrent request failed (HTTP 500)"),
    ("abc: Playlist nicht verfügbar", "abc: Playlist unavailable"),
    (
        "„Meine Songs“: Spotify gibt die Songs dieser Playlist nicht frei",
        "“Meine Songs”: Spotify does not provide the songs in this playlist",
    ),
    (
        "„Meine Songs“: nur die ersten 100 Songs übernommen (ohne verbundenes Spotify-Konto liefert Spotify nicht mehr)",
        "“Meine Songs”: only the first 100 songs were imported (Spotify does not provide more without a connected Spotify account)",
    ),
    ("Parameter fehlt: query", "Missing parameter: query"),
    ("Ungültiger Parameter: count", "Invalid parameter: count"),
    ("Artist, Other und mehr", "Artist, Other and more"),
    ("Das Beste aus Rock in deiner Bibliothek", "The best of Rock in your library"),
    ("Durchsuche /data/music …", "Scanning /data/music …"),
    ("2/5 Dateien verarbeitet", "2/5 files processed"),
    ("9 Dateien, 2 neu/geändert, 1 entfernt", "9 files, 2 new/changed, 1 removed"),
    ("  Value error, Ungültige Adresse [type=value_error]", "  Value error, Invalid address [type=value_error]"),
    ("abc: Spotify nicht erreichbar", "abc: Spotify is unavailable"),
    ("abc: Playlist nicht gefunden oder privat", "abc: Playlist not found or private"),
    ("Verbindung fehlgeschlagen: Spotify nicht erreichbar", "Connection failed: Spotify is unavailable"),
    (
        "Verbindung fehlgeschlagen: Spotify-Verbindung abgelaufen – bitte neu verbinden",
        "Connection failed: Spotify connection expired – please reconnect",
    ),
    (
        "Verbindung fehlgeschlagen: Spotify-Limit erreicht – bitte später erneut versuchen",
        "Connection failed: Spotify rate limit reached – please try again later",
    ),
    ("Verbindung fehlgeschlagen: Ungültiger oder abgelaufener Status", "Connection failed: Invalid or expired state"),
    ("Verbindung fehlgeschlagen: Autorisierungscode fehlt", "Connection failed: Authorization code is missing"),
    ("abc: Spotify-Fehler (HTTP 502)", "abc: Spotify error (HTTP 502)"),
    ("Verbindung fehlgeschlagen: Spotify-Fehler (HTTP 500)", "Connection failed: Spotify error (HTTP 500)"),
    ("Verbindung fehlgeschlagen: access_denied", "Connection failed: access_denied"),
]


@pytest.mark.parametrize("message,english", PATTERN_CASES)
def test_patterns(message: str, english: str) -> None:
    assert translate(message, "en") == english
    assert translate(message, "de") == message


def test_every_pattern_is_exercised() -> None:
    for pattern, _ in _PATTERNS:
        assert any(pattern.fullmatch(message) for message, _ in PATTERN_CASES), pattern.pattern


def test_multiline_and_unknown() -> None:
    message = "Import fehlgeschlagen\nabc: Spotify nicht erreichbar\nMy playlist\n"
    assert translate(message, "en") == "Import failed\nabc: Spotify is unavailable\nMy playlist\n"
    assert translate(message, "de") == message
    assert translate("prefix Import fehlgeschlagen suffix", "en") == "prefix Import fehlgeschlagen suffix"


def test_http_exception_literals_have_exact_entries() -> None:
    missing = []
    for path in (Path(__file__).parents[1] / "app").rglob("*.py"):
        source = path.read_text()
        # Grep for candidate files, then parse calls to handle multiline and keyword arguments correctly.
        if not re.search(r"\bHTTPException\s*\(", source):
            continue
        for node in ast.walk(ast.parse(source)):
            if not isinstance(node, ast.Call):
                continue
            name = (
                node.func.id
                if isinstance(node.func, ast.Name)
                else node.func.attr
                if isinstance(node.func, ast.Attribute)
                else None
            )
            if name != "HTTPException":
                continue
            detail = next((kw.value for kw in node.keywords if kw.arg == "detail"), None)
            if detail is None and len(node.args) > 1:
                detail = node.args[1]
            if isinstance(detail, ast.Constant) and isinstance(detail.value, str) and detail.value not in _EXACT:
                missing.append(f"{path.name}:{node.lineno}: {detail.value}")
    assert not missing, "\n".join(missing)


@pytest.mark.parametrize("exception", [HTTPException, StarletteHTTPException])
async def test_http_handler_preserves_status_headers_and_structured_detail(
    exception: type[StarletteHTTPException],
) -> None:
    request = Request({"type": "http", "headers": [(b"accept-language", b"en")]})
    response = await http_exception(request, exception(429, "Nicht gefunden", {"Retry-After": "5"}))
    assert response.status_code == 429
    assert response.headers["Retry-After"] == "5"
    assert json.loads(response.body) == {"detail": "Not found"}
    response = await http_exception(request, exception(400, {"message": "Nicht gefunden"}))
    assert json.loads(response.body) == {"detail": {"message": "Nicht gefunden"}}


async def test_validation_errors_are_unchanged() -> None:
    app = FastAPI()
    app.add_exception_handler(StarletteHTTPException, http_exception)

    @app.get("/")
    async def endpoint(number: int) -> int:
        return number

    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        german = await client.get("/?number=no", headers={"Accept-Language": "de"})
        english = await client.get("/?number=no", headers={"Accept-Language": "en"})
    assert german.status_code == english.status_code == 422
    assert german.json() == english.json()


async def test_stored_messages_translate_only_on_output(client: httpx.AsyncClient) -> None:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.drop_all)
        await connection.run_sync(Base.metadata.create_all)
    account = await register(client, "i18n-admin")
    user_id = uuid.UUID(account["user"]["id"])
    async with SessionLocal() as db:
        download = DownloadRequest(
            user_id=user_id,
            kind="track",
            title="Song",
            artist="Artist",
            status="failed",
            torrent_error="Torrent ohne Fortschritt",
            note="Notiz des Nutzers",
        )
        db.add(download)
        batch = ImportBatch(
            kind="import", mode="copy", source_dir="/import", status="failed", message="Durch Neustart abgebrochen"
        )
        spotify = SpotifyImport(
            user_id=user_id,
            status="failed",
            liked=True,
            playlist_ids=[],
            download_missing=False,
            message="Import fehlgeschlagen\nabc: Playlist nicht verfügbar",
            missing_tracks=[
                {"title": "Song", "source": "Lieblingssongs"},
                {"title": "Song", "source": "Neu für dich"},
            ],
        )
        job = Job(kind="library_scan", status="done", message="2 Dateien, 1 neu/geändert, 0 entfernt")
        mix = Playlist(
            owner_id=user_id,
            kind="mix",
            name="Neu für dich",
            description="Songs aus deiner Bibliothek, die du noch nicht gehört hast",
        )
        user_playlist = Playlist(owner_id=user_id, kind="user", name="Neu für dich", description="Lange nicht gehört")
        db.add_all([batch, spotify, job, mix, user_playlist])
        await db.flush()
        item = DownloadItem(
            request_id=download.id,
            position=0,
            title="Song",
            artist="Artist",
            meta={},
            status="failed",
            error="Download fehlgeschlagen: Originalfehler",
        )
        file = ImportFile(
            batch_id=batch.id, path="broken.opus", group_key="", status="failed", error="Audiodatei nicht lesbar"
        )
        db.add_all([item, file])
        await db.commit()
        ids = download.id, batch.id, spotify.id, job.id, mix.id, user_playlist.id

    for header, english in [(None, False), ("de-DE,en", False), ("en,de", True), ("fr", True)]:
        headers = auth(account["token"])
        if header is not None:
            headers["Accept-Language"] = header
        download_out = (await client.get(f"/api/requests/{ids[0]}", headers=headers)).json()
        assert download_out["torrent_error"] == (
            "Torrent is not making progress" if english else "Torrent ohne Fortschritt"
        )
        assert download_out["items"][0]["error"] == (
            "Download failed: Originalfehler" if english else "Download fehlgeschlagen: Originalfehler"
        )
        assert download_out["note"] == "Notiz des Nutzers"
        batch_out = (await client.get(f"/api/admin/imports/{ids[1]}", headers=headers)).json()
        assert batch_out["message"] == ("Cancelled by a server restart" if english else "Durch Neustart abgebrochen")
        files = (await client.get(f"/api/admin/imports/{ids[1]}/files", headers=headers)).json()
        assert files["items"][0]["error"] == ("Audio file cannot be read" if english else "Audiodatei nicht lesbar")
        spotify_out = (await client.get(f"/api/spotify/imports/{ids[2]}", headers=headers)).json()
        assert spotify_out["message"] == ("Import failed\nabc: Playlist unavailable" if english else spotify.message)
        assert spotify_out["missing_tracks"][0]["source"] == ("Liked Songs" if english else "Lieblingssongs")
        assert spotify_out["missing_tracks"][1]["source"] == "Neu für dich"
        error = await client.post(
            "/api/auth/login", json={"username": "no-user", "password": "password123"}, headers=headers
        )
        assert error.status_code == 401
        assert error.json()["detail"] == (
            "Incorrect username or password" if english else "Benutzername oder Passwort falsch"
        )
        subsonic = (await client.get("/rest/ping.view?f=json", headers=headers)).json()["subsonic-response"]
        assert subsonic["error"] == {"code": 10, "message": "Missing parameter: u" if english else "Parameter fehlt: u"}
        jobs = (await client.get("/api/admin/jobs", headers=headers)).json()
        assert jobs[0]["message"] == ("2 files, 1 new/changed, 0 removed" if english else job.message)
        abs_status = (await client.get("/api/admin/abs/status", headers=headers)).json()
        assert abs_status["message"] == ("No address configured" if english else "Keine Adresse eingetragen")
        config_error = await client.patch(
            "/api/admin/config", json={"audiobookshelf": {"url": "not-a-url"}}, headers=headers
        )
        assert config_error.status_code == 422
        assert ("Invalid address" if english else "Ungültige Adresse") in config_error.json()["detail"]
        mix_out = (await client.get(f"/api/playlists/{ids[4]}", headers=headers)).json()
        assert mix_out["name"] == ("New for you" if english else "Neu für dich")
        playlist_out = (await client.get(f"/api/playlists/{ids[5]}", headers=headers)).json()
        assert playlist_out["name"] == "Neu für dich"

    async with SessionLocal() as db:
        assert (await db.get(DownloadItem, item.id)).error == "Download fehlgeschlagen: Originalfehler"
        assert (await db.get(DownloadRequest, ids[0])).torrent_error == "Torrent ohne Fortschritt"
        assert (await db.get(SpotifyImport, ids[2])).missing_tracks[0]["source"] == "Lieblingssongs"
