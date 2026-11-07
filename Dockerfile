# Dawri: one container, one process. FastAPI serves the API and the built frontend.
# No platform is set here, because Hugging Face Spaces build on linux/amd64.

# Stage 1: build the frontend. Vite 8 needs Node 20.19 or later.
FROM node:22.23.4-trixie-slim AS frontend
WORKDIR /build/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

# Stage 2: the runtime. Everything under /app stays root-owned, so the app cannot change it.
FROM python:3.12.16-slim-trixie
RUN groupadd --gid 1000 dawri \
    && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin dawri
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ /app/backend/
COPY --from=frontend /build/frontend/dist/ /app/backend/static/
RUN chown -R root:root /app && chmod -R a+rX,go-w /app

# Spaces run as uid 1000 with a read-only app tree, so all writes go to /tmp.
ENV DAWRI_DB=/tmp/dawri.db \
    SIMULATE_LOAD=1 \
    PORT=7860 \
    HOME=/tmp \
    HF_HOME=/tmp/hf \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER 1000
EXPOSE 7860

# Slim has no curl. urlopen raises on anything but a 2xx, so a failed check exits non-zero.
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:7860/api/health', timeout=4)"]

# One process only, because the event bus lives in this process. The graceful timeout
# stops an open SSE stream from holding up a stop, and the token in a stream URL stays
# out of the logs because the access log is off.
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "7860", "--timeout-graceful-shutdown", "3", "--no-access-log"]
