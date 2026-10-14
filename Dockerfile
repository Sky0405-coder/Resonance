# --- Flutter web build -------------------------------------------------------
# Pinned to the same Flutter release used for development (see app/pubspec.yaml SDK constraint).
FROM debian:bookworm-slim AS web
ARG FLUTTER_VERSION=3.47.7
RUN apt-get update \
    && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 -b ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH \
    TAR_OPTIONS=--no-same-owner
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /src/app
COPY app/pubspec.yaml app/pubspec.lock ./
RUN flutter pub get
COPY app/ ./
# --wasm: the skwasm renderer keeps decoded images across rebuilds; with CanvasKit, covers went blank after
# navigating back. Browsers without WasmGC fall back to the CanvasKit build automatically.
RUN flutter build web --release --wasm

# --- Server ------------------------------------------------------------------
FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=docker.io/denoland/deno:bin /deno /usr/local/bin/deno
WORKDIR /srv
COPY backend/pyproject.toml ./
COPY backend/app ./app
RUN pip install --no-cache-dir .
COPY backend/alembic.ini ./
COPY backend/migrations ./migrations
COPY --from=web /src/app/build/web /srv/web

ENV RESONANCE_WEB_DIR=/srv/web \
    RESONANCE_MUSIC_DIR=/data/music \
    RESONANCE_DATA_DIR=/data/app \
    PYTHONUNBUFFERED=1

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/health')"
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips='*'"]
