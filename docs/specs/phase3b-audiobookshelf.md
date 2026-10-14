# Phase 3b – Audiobookshelf proxy (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md` §0 (only
`backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use `httpx.MockTransport`). Run tests against the database `app_test` only.

## Context
The user already runs Audiobookshelf (ABS) 2.34 at e.g. `https://audio.k-node.de`. The Resonance client
gets an "Hörbücher" tab. Every Resonance user links their *own* ABS account once (ABS username +
password); the Resonance server stores that user's ABS refresh token and proxies the ABS REST API so the
client never needs CORS, ABS credentials or ABS tokens. The client talks to ABS's normal API shape through
`/api/abs/api/...` (see §4) – the backend does **not** reshape ABS JSON.

ABS 2.34 auth facts (verified in its source, `server/Auth.js`, `server/auth/TokenManager.js`):
- `POST {abs}/login` JSON `{"username","password"}` with header `x-return-tokens: true` → 200 JSON
  `{"user": {"id", "username", "accessToken", "refreshToken", ...}, ...}`; wrong credentials → 401.
- `POST {abs}/auth/refresh` with header `x-refresh-token: <refresh>` → 200 JSON
  `{"user": {"accessToken", "refreshToken", ...}}`. **The refresh token rotates** – always store the new one.
  Invalid/expired → 401. Access tokens live 1 h, refresh tokens 30 days (renewed on every refresh).
- `POST {abs}/logout` with header `x-refresh-token` invalidates the session.
- API calls: `Authorization: Bearer <accessToken>`; expired access token → 401.
- `POST /api/items/{id}/play` with body `{"deviceInfo": {...}, "forceDirectPlay": true, "mediaPlayer": "resonance",
  "supportedMimeTypes": [...]}` returns a session whose `audioTracks[].contentUrl` is
  `/api/items/{id}/file/{ino}` (direct play).

## 1. Config
`ServerConfig.audiobookshelf: AudiobookshelfConfig` (new section):
```python
class AudiobookshelfConfig(BaseModel):
    # Show the "Hörbücher" tab and allow users to link their Audiobookshelf account.
    enabled: bool = False
    # Base URL of the Audiobookshelf server as reachable from the Resonance server, e.g. https://audio.k-node.de
    url: str = ""
```
`url` is stored with trailing `/` stripped; non-empty values must start with `http://` or `https://`
(validator → 422 `"Ungültige Adresse"`).

## 2. Model + alembic revision
```python
class AudiobookshelfAccount(Base):
    __tablename__ = "audiobookshelf_accounts"
    user_id: UUID PK, FK users.id ON DELETE CASCADE
    abs_user_id: String(64)
    abs_username: String(256)
    refresh_token: Text
    access_token: Text | None
    access_expires_at: DateTime(tz) | None
    created_at / updated_at (server_default now, updated_at onupdate now)
```

## 3. Service `app/services/audiobookshelf.py`
- `class ABSError(Exception)` with `status: int` and German `message`.
- `async def login(cfg, username, password) -> dict` (returns the `user` object). Connection errors →
  `ABSError(502, "Audiobookshelf nicht erreichbar")`; 401 → `ABSError(401, "Benutzername oder Passwort falsch")`;
  other non-2xx → `ABSError(502, f"Audiobookshelf-Fehler (HTTP {code})")`. Timeout 20 s.
- `async def access_token(db, account) -> str`: if `access_token` and `access_expires_at > now + 60 s` → return
  it; else refresh, store new access token, `access_expires_at = now + 50 min`, **new refresh token**, commit.
  Refresh 401 → delete the account row, commit, `ABSError(401, "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden")`.
  Concurrency: guard refresh per user with an `asyncio.Lock` held in a module-level `dict[uuid, Lock]` so two
  parallel requests do not both rotate the token (the second one re-reads the row after acquiring the lock).
- `async def request(db, account, method, path, *, params, json, headers) -> httpx.Response` – one shared
  `httpx.AsyncClient` (module level, created lazily, closed in the app lifespan shutdown), timeout 30 s
  (connect 10 s, read `None` for streaming, see §4). On a 401 from ABS: force refresh once and retry once.

## 4. API – new router `app/api/audiobookshelf.py`, prefix `/api/abs`, all endpoints `CurrentUser`
1. `GET /status` → `{"enabled": bool, "url": str, "linked": bool, "username": str | None}`.
   `url` is the configured ABS URL (shown in the client for external apps).
2. `POST /login` body `{"username": str (1..256), "password": str (1..1024)}` → same shape as `/status`.
   Disabled or empty `url` → 409 `"Audiobookshelf ist nicht eingerichtet"`. Success → upsert the account
   (store `user.id`, `user.username`, `refreshToken`, `accessToken`, expiry now + 50 min).
3. `DELETE /login` → 204; best-effort `POST {abs}/logout` with the refresh token (errors ignored); delete row.
4. **Proxy** `GET|POST|PATCH|DELETE /api/{path:path}` → forwards to `{abs}/api/{path}`:
   - Allowed path prefixes (after `api/`), anything else → 404:
     `libraries`, `items`, `me`, `session`, `series`, `authors`, `collections`, `playlists`, `search`.
     Reject paths containing `..` or starting with `/` → 404.
   - Not enabled → 409 as above; not linked → 409 `"Kein Audiobookshelf-Konto verbunden"`.
   - Forward query params **except** `token` (Resonance auth); forward request body bytes for
     POST/PATCH/DELETE with `content-type`; forward request header `range` and `if-none-match`.
     Never forward the client's `authorization`/`cookie` headers.
   - Response: status code as from ABS (401 after the retry → 401 with the §3 message, the account is not
     deleted unless refresh failed); `StreamingResponse` over `response.aiter_raw()` (use
     `client.send(request, stream=True)`, close the response in a `BackgroundTask`). Pass through headers
     `content-type, content-length, content-range, accept-ranges, etag, cache-control, last-modified`.
     ABS JSON is passed through unchanged.
   - Audio files (`items/{id}/file/{ino}`) and covers (`items/{id}/cover`) therefore work with `?token=`
     on the Resonance side, exactly like `/api/library/tracks/{id}/stream`.
5. Remove the Resonance account from ABS-linked state when the Resonance user is deleted (FK cascade
   is enough).

## 5. Admin
`GET /api/admin/abs/status` (admin) → `{"ok": bool, "message": str}`: `GET {abs}/status` (public ABS
endpoint, JSON contains `serverVersion`) → `"Version {serverVersion}"`; not configured → `ok=false`,
`"Keine Adresse eingetragen"`; errors → `"Audiobookshelf nicht erreichbar"`. Put it in the same router file
with a second `APIRouter(prefix="/api/admin/abs")`.

## 6. Tests (`tests/test_audiobookshelf.py`, no network – mock ABS with `httpx.MockTransport` by
monkeypatching the module's client factory)
login success/401/unreachable/not enabled; status; proxy GET JSON pass-through incl. query params and
stripped `token`; disallowed prefix and `..` → 404; streaming with `Range` → 206 and `content-range`
passed through; POST body forwarding (`items/x/play`); expired access token → refresh → retry, refresh
token rotated and stored; two concurrent requests with an expired token refresh only once; refresh 401 →
account deleted + 401; logout; admin status endpoint; config validation of `url`; per-user isolation (user B
cannot use user A's account). All existing tests stay green.

## 7. Report
Files, pytest tail, migration check (`alembic upgrade head` on a fresh DB + `alembic check`), deviations
(or "none").
