import asyncio
import time

import httpx

_lock = asyncio.Lock()
_last_started = 0.0


class AcoustIDError(Exception):
    pass


async def lookup(api_key: str, fingerprint: str, duration: float) -> list[dict]:
    global _last_started
    form = {
        "client": api_key,
        "meta": "recordings releasegroups releases tracks compress",
        "duration": int(round(duration)),
        "fingerprint": fingerprint,
    }
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            for attempt in range(3):
                async with _lock:
                    await asyncio.sleep(max(0, 0.34 - (time.monotonic() - _last_started)))
                    _last_started = time.monotonic()
                    response = await client.post("https://api.acoustid.org/v2/lookup", data=form)
                if response.status_code in {429, 503} and attempt < 2:
                    await asyncio.sleep(2)
                    continue
                response.raise_for_status()
                data = response.json()
                if data.get("status") != "ok":
                    raise AcoustIDError(str(data.get("error", "AcoustID-Anfrage fehlgeschlagen")))
                return data.get("results", [])
    except (httpx.HTTPError, ValueError) as e:
        raise AcoustIDError(str(e)) from e
    return []
