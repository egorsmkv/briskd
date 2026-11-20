# rtpengine media relay for WebIRC voice calls (development and testing).
# Debian's rtpengine-daemon runs in userspace mode (no kernel module).
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends rtpengine-daemon \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/rtpengine-entrypoint
ENTRYPOINT ["/usr/local/bin/rtpengine-entrypoint"]
