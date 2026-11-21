# rtpengine media relay for WebIRC calls (development and testing).
# Debian's rtpengine-daemon runs in userspace mode (no kernel module).
# Not Alpine: its rtpengine package (12.2.1.4-r2 on Alpine 3.24) fails the
# DTLS handshake with Chromium, so browser calls end a second after ICE
# connects, while Debian's 12.2 works (test/calls/browser/run).
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends rtpengine-daemon \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/rtpengine-entrypoint
ENTRYPOINT ["/usr/local/bin/rtpengine-entrypoint"]
