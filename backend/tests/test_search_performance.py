import asyncio
import uuid
from io import BytesIO

from PIL import Image

from app.api.library import search_queries
from app.db import engine
from app.services import covers


async def test_track_search_uses_every_trigram_index() -> None:
    query = search_queries("ab12")[2]
    sql = str(query.compile(dialect=engine.dialect, compile_kwargs={"literal_binds": True}))
    async with engine.begin() as conn:
        # The table is empty here: without these the planner may just walk any index.
        await conn.exec_driver_sql("SET LOCAL enable_seqscan = off")
        await conn.exec_driver_sql("SET LOCAL enable_indexscan = off")
        plan = "\n".join(row[0] for row in await conn.exec_driver_sql("EXPLAIN " + sql))
    for index in (
        "ix_tracks_title_trgm",
        "ix_tracks_title_compact_trgm",
        "ix_tracks_artist_credit_trgm",
        "ix_tracks_artist_credit_compact_trgm",
    ):
        assert index in plan


async def test_concurrent_resizes_leave_one_complete_file() -> None:
    image = BytesIO()
    Image.effect_noise((800, 800), uuid.uuid4().int % 90 + 10).convert("RGB").save(image, "PNG")
    name = covers.store(image.getvalue())

    paths = await asyncio.gather(*(asyncio.to_thread(covers.resized, name, 64) for _ in range(8)))

    assert len(set(paths)) == 1
    with Image.open(paths[0]) as resized:
        resized.load()
        assert max(resized.size) == 64
    assert not list(paths[0].parent.glob("*.part"))
