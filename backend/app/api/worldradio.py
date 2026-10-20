import asyncio
import ipaddress
import socket
from collections.abc import AsyncIterator
from typing import Any

import anyio
import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import Response, StreamingResponse
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from starlette.background import BackgroundTask

from app.deps import DB, CurrentUser
from app.models import RadioStationFavorite
from app.schemas import NowPlayingOut
from app.services import worldradio
from app.services.worldradio import Station, WorldRadioError

router = APIRouter(prefix="/api/worldradio", tags=["worldradio"])


@router.get("/countries")
async def countries(user: CurrentUser) -> list[dict[str, Any]]:
    try:
        return await worldradio.countries()
    except WorldRadioError as exc:
        raise HTTPException(502, "Radiosender-Verzeichnis nicht erreichbar") from exc


@router.get("/tags")
async def tags(user: CurrentUser) -> list[str]:
    try:
        return await worldradio.top_tags()
    except WorldRadioError as exc:
        raise HTTPException(502, "Radiosender-Verzeichnis nicht erreichbar") from exc


@router.get("/stations")
async def stations(
    user: CurrentUser,
    country: str = "",
    tag: str = "",
    q: str = "",
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=100),
) -> list[Station]:
    try:
        return await worldradio.search(country, tag, q, offset, limit)
    except WorldRadioError as exc:
        raise HTTPException(502, "Radiosender-Verzeichnis nicht erreichbar") from exc


async def _station(id: str) -> Station:
    try:
        station = await worldradio.station(id)
    except WorldRadioError as exc:
        raise HTTPException(502, "Radiosender-Verzeichnis nicht erreichbar") from exc
    if station is None:
        raise HTTPException(404, "Sender nicht gefunden")
    return station


@router.get("/stations/{id}")
async def station(id: str, user: CurrentUser) -> Station:
    return await _station(id)


@router.get("/stations/{id}/now")
async def now_playing(id: str, user: CurrentUser) -> NowPlayingOut | None:
    entry = worldradio.now_playing(id)
    return NowPlayingOut.model_validate(entry) if entry else None


@router.get("/favorites")
async def favorites(user: CurrentUser, db: DB) -> list[Station]:
    rows = await db.scalars(
        select(RadioStationFavorite)
        .where(RadioStationFavorite.user_id == user.id)
        .order_by(RadioStationFavorite.created_at.desc())
    )
    return [Station.model_validate(row.data) for row in rows]


@router.put("/favorites/{id}", status_code=204)
async def add_favorite(id: str, user: CurrentUser, db: DB) -> Response:
    station = await _station(id)
    statement = insert(RadioStationFavorite).values(user_id=user.id, station_id=id, data=station.model_dump())
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["user_id", "station_id"], set_={"data": statement.excluded.data}
        )
    )
    await db.commit()
    return Response(status_code=204)


@router.delete("/favorites/{id}", status_code=204)
async def remove_favorite(id: str, user: CurrentUser, db: DB) -> Response:
    await db.execute(
        delete(RadioStationFavorite).where(
            RadioStationFavorite.user_id == user.id, RadioStationFavorite.station_id == id
        )
    )
    await db.commit()
    return Response(status_code=204)


async def _validate_url(request: httpx.Request) -> None:
    url = request.url
    if url.scheme not in {"http", "https"} or not url.host:
        raise HTTPException(502, "Sender nicht erreichbar")
    try:
        addresses = await asyncio.wait_for(
            asyncio.get_running_loop().getaddrinfo(url.host, url.port, type=socket.SOCK_STREAM), timeout=10
        )
        if not addresses:
            raise ValueError("No addresses")
        for address in addresses:
            ip = ipaddress.ip_address(address[4][0])
            if not ip.is_global or ip.is_multicast or ip.is_reserved:
                raise ValueError("Non-public address")
    except (OSError, ValueError, TimeoutError) as exc:
        raise HTTPException(502, "Sender nicht erreichbar") from exc


def _stream_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        follow_redirects=True, timeout=httpx.Timeout(10, read=None), event_hooks={"request": [_validate_url]}
    )


@router.get("/stations/{id}/stream")
async def stream(id: str, user: CurrentUser) -> StreamingResponse:
    station = await _station(id)
    client = _stream_client()
    try:
        upstream = await client.send(
            client.build_request("GET", station._url_resolved, headers={"Icy-MetaData": "1"}), stream=True
        )
        if not 200 <= upstream.status_code < 300:
            await upstream.aclose()
            raise HTTPException(502, "Sender nicht erreichbar")
    except (httpx.HTTPError, httpx.InvalidURL, HTTPException) as exc:
        await client.aclose()
        raise HTTPException(502, "Sender nicht erreichbar") from exc

    click_task = asyncio.create_task(worldradio.click(id))
    try:
        metaint = int(upstream.headers.get("icy-metaint", "0"))
    except ValueError:
        metaint = 0
    reader = worldradio.IcyReader(metaint) if metaint > 0 else None
    worldradio.stream_started(id)
    closed = False

    async def close() -> None:
        nonlocal closed
        if closed:
            return
        closed = True
        worldradio.stream_stopped(id)
        await upstream.aclose()
        await client.aclose()
        await click_task

    async def chunks() -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream.aiter_bytes():
                if reader is not None:
                    chunk, titles = reader.feed(chunk)
                    for title in titles:
                        worldradio.set_now_playing(id, station.name, title)
                if chunk:
                    yield chunk
        finally:
            with anyio.CancelScope(shield=True):
                await close()

    headers = {"Cache-Control": "no-store"}
    if content_type := upstream.headers.get("content-type"):
        headers["Content-Type"] = content_type
    return StreamingResponse(chunks(), headers=headers, background=BackgroundTask(close))
