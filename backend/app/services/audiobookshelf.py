import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AudiobookshelfAccount
from app.services.server_config import AudiobookshelfConfig, load_config

_client: httpx.AsyncClient | None = None
_refresh_locks: dict[uuid.UUID, asyncio.Lock] = {}


class ABSError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=httpx.Timeout(30, connect=10, read=None))


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = _client_factory()
    return _client


async def close() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


async def login(cfg: AudiobookshelfConfig, username: str, password: str) -> dict:
    try:
        response = await _get_client().post(
            f"{cfg.url}/login",
            json={"username": username, "password": password},
            headers={"x-return-tokens": "true"},
            timeout=20,
        )
    except httpx.HTTPError as e:
        raise ABSError(502, "Audiobookshelf nicht erreichbar") from e
    if response.status_code == 401:
        raise ABSError(401, "Benutzername oder Passwort falsch")
    if not response.is_success:
        raise ABSError(502, f"Audiobookshelf-Fehler (HTTP {response.status_code})")
    try:
        return response.json()["user"]
    except (ValueError, KeyError) as e:
        raise ABSError(502, "Audiobookshelf nicht erreichbar") from e


def _valid(account: AudiobookshelfAccount) -> bool:
    return bool(
        account.access_token
        and account.access_expires_at
        and account.access_expires_at > datetime.now(UTC) + timedelta(seconds=60)
    )


async def _refresh(db: AsyncSession, account: AudiobookshelfAccount, rejected_token: str | None = None) -> str:
    lock = _refresh_locks.setdefault(account.user_id, asyncio.Lock())
    async with lock:
        current = await db.scalar(
            select(AudiobookshelfAccount)
            .where(AudiobookshelfAccount.user_id == account.user_id)
            .execution_options(populate_existing=True)
        )
        if current is None:
            raise ABSError(401, "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden")
        if _valid(current) and (rejected_token is None or current.access_token != rejected_token):
            return current.access_token
        cfg = (await load_config(db)).audiobookshelf
        try:
            response = await _get_client().post(
                f"{cfg.url}/auth/refresh", headers={"x-refresh-token": current.refresh_token}, timeout=20
            )
        except httpx.HTTPError as e:
            raise ABSError(502, "Audiobookshelf nicht erreichbar") from e
        if response.status_code == 401:
            await db.delete(current)
            await db.commit()
            raise ABSError(401, "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden")
        if not response.is_success:
            raise ABSError(502, f"Audiobookshelf-Fehler (HTTP {response.status_code})")
        try:
            user = response.json()["user"]
            token, refresh_token = user["accessToken"], user["refreshToken"]
        except (ValueError, KeyError) as e:
            raise ABSError(502, "Audiobookshelf nicht erreichbar") from e
        current.access_token = token
        current.refresh_token = refresh_token
        current.access_expires_at = datetime.now(UTC) + timedelta(minutes=50)
        await db.commit()
        return token


async def access_token(db: AsyncSession, account: AudiobookshelfAccount) -> str:
    if _valid(account):
        return account.access_token
    return await _refresh(db, account)


async def request(
    db: AsyncSession,
    account: AudiobookshelfAccount,
    method: str,
    path: str,
    *,
    params: Any,
    json: Any,
    headers: dict[str, str],
) -> httpx.Response:
    cfg = (await load_config(db)).audiobookshelf
    client = _get_client()
    token = await access_token(db, account)
    for attempt in range(2):
        # The proxy streams raw bytes without Content-Encoding, so ABS must not compress (Cloudflare compresses anyway).
        outgoing_headers = {**headers, "authorization": f"Bearer {token}", "accept-encoding": "identity"}
        body = {"content": json} if isinstance(json, bytes) else {"json": json}
        outgoing = client.build_request(
            method, f"{cfg.url}/api/{path}", params=params, headers=outgoing_headers, **body
        )
        try:
            response = await client.send(outgoing, stream=True)
        except httpx.HTTPError as e:
            raise ABSError(502, "Audiobookshelf nicht erreichbar") from e
        if response.status_code != 401:
            return response
        await response.aclose()
        if attempt == 0:
            token = await _refresh(db, account, rejected_token=token)
    raise ABSError(401, "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden")
