import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

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
    playlists,
    requests,
    torrents,
)
from app.config import get_settings
from app.services import audiobookshelf as abs_service
from app.services import importer
from app.services.downloads import manager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if settings.download_workers > 0:
        await manager.start()
    await importer.start()
    try:
        yield
    finally:
        await importer.stop()
        await manager.stop()
        await abs_service.close()


app = FastAPI(title="Resonance", version="0.1.0", lifespan=lifespan)
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
    admin,
    catalog,
    requests,
    imports,
    torrents,
    editor,
    audiobookshelf,
):
    app.include_router(module.router)
app.include_router(audiobookshelf.admin_router)


@app.get("/api/health", tags=["system"])
async def health() -> dict:
    return {"status": "ok", "version": app.version}


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
