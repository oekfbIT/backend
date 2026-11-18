# Veo sync worker (DigitalOcean App Platform "Worker" component, or any Docker host).
# Build from the repo root:  docker build -f tools/veo-sync/Dockerfile tools/veo-sync
FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    VEO_SYNC_HEADLESS=true \
    VEO_SYNC_CLEANUP=true \
    TZ=Europe/Vienna

WORKDIR /app

# Dependencies + Chromium (with its system libraries) + ffmpeg (optional, only for the full match video).
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
 && npx playwright install --with-deps chromium \
 && apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/* /root/.npm

COPY src ./src

# Run as an unprivileged user; it needs to write login state, captures and downloads under /app.
RUN useradd --create-home --home-dir /home/veo veo \
 && mkdir -p /app/.auth /app/captures /app/downloads \
 && chown -R veo:veo /app
USER veo

# Polls the backend for queued jobs (admin button) and runs them.
CMD ["node", "src/index.mjs", "worker"]
