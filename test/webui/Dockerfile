# Headless Chromium and puppeteer-core for test/webui/shoot.mjs.
FROM node:22.12.0-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends chromium fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /m
RUN npm init -y >/dev/null && npm install puppeteer-core@23.11.1 >/dev/null
