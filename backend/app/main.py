import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api import (
    admin,
    app_updates,
    audiobookshelf,
    auth,
    catalog,
    editor,
    imports,
    library,
    me,
    mixes,
    playlists,
    radio,
    requests,
    spotify,
    subsonic,
    torrents,
    users,
)
from app.config import get_settings
from app.deps import DB, CurrentUser
from app.i18n import language, translate
from app.services import audiobookshelf as abs_service
from app.services import importer, upgrades
from app.services import mixes as mixes_service
from app.services import radio as radio_service
from app.services import spotify as spotify_service
from app.services.downloads import manager
from app.services.server_config import load_config

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if settings.download_workers > 0:
        await manager.start()
    await importer.start()
    await spotify_service.start()
    await radio_service.start()
    await mixes_service.start()
    await upgrades.start()
    try:
        yield
    finally:
        await upgrades.stop()
        await importer.stop()
        await manager.stop()
        await spotify_service.stop()
        await radio_service.stop()
        await mixes_service.stop()
        await abs_service.close()


app = FastAPI(title="Resonance", version="0.1.0", lifespan=lifespan)


@app.exception_handler(HTTPException)
@app.exception_handler(StarletteHTTPException)
async def http_exception(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    detail = translate(exc.detail, language(request)) if isinstance(exc.detail, str) else exc.detail
    return JSONResponse({"detail": detail}, status_code=exc.status_code, headers=exc.headers)


app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["Content-Range", "Accept-Ranges", "Content-Length"],
)

for module in (
    app_updates,
    auth,
    me,
    library,
    playlists,
    radio,
    mixes,
    admin,
    catalog,
    requests,
    spotify,
    subsonic,
    imports,
    torrents,
    editor,
    audiobookshelf,
    users,
):
    app.include_router(module.router)
app.include_router(audiobookshelf.admin_router)
app.include_router(editor.editor_router)


@app.get("/api/health", tags=["system"])
async def health() -> dict:
    return {"status": "ok", "version": app.version}


@app.get("/api/client-config", tags=["system"])
async def client_config(user: CurrentUser, db: DB) -> dict[str, str]:
    config = await load_config(db)
    return {"discord_client_id": config.integrations.discord_client_id}


def _mount_web(web_dir: Path) -> None:
    """Serve the Flutter web build with SPA fallback to index.html."""
    index = web_dir / "index.html"
    app.mount("/assets", StaticFiles(directory=web_dir / "assets"), name="web-assets")

    @app.get("/{path:path}", include_in_schema=False)
    async def spa(path: str) -> FileResponse:
        if path.startswith("api/"):
            raise HTTPException(404)
        candidate = (web_dir / path).resolve()
        if path and candidate.is_file() and candidate.is_relative_to(web_dir.resolve()):
            # App files keep their names across builds: always revalidate (also stops Cloudflare from caching them).
            return FileResponse(candidate, headers={"Cache-Control": "no-cache"})
        return FileResponse(index, headers={"Cache-Control": "no-cache"})


if settings.web_dir and (settings.web_dir / "index.html").is_file():
    _mount_web(settings.web_dir)
