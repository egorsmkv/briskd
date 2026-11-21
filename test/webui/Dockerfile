# Headless Chromium and puppeteer-core for the browser tests
# (test/webui/shoot.mjs, test/calls/browser/video_call.mjs). Alpine's
# Chromium ships no fonts: DejaVu covers the UI's Latin, Cyrillic, and Hebrew,
# and Noto Emoji the emoji (all of font-noto would add about 500 MB).
FROM alpine:3.24.4
RUN apk add --no-cache nodejs npm chromium font-dejavu font-noto-emoji
WORKDIR /m
RUN npm init -y >/dev/null && npm install puppeteer-core@23.11.1 >/dev/null \
    && npm cache clean --force >/dev/null 2>&1
