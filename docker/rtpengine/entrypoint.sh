#!/bin/sh
# Bind media on the container address and advertise RTPENGINE_ADVERTISE
# (default: the container address) in SDP. The NG control port listens on
# RTPENGINE_NG_PORT (UDP). Media uses RTPENGINE_PORT_MIN..RTPENGINE_PORT_MAX.
set -eu
# `hostname -i` prints every address. The first one is the address media
# binds to. A pipeline would hide a failure from hostname, so an empty
# result is checked afterwards.
LOCAL_IP=$(hostname -i 2>/dev/null | awk 'NF { print $1; exit }' || true)
if [ -z "$LOCAL_IP" ]; then
    echo "rtpengine-entrypoint: hostname -i did not return an address" >&2
    exit 1
fi
ADVERTISE=${RTPENGINE_ADVERTISE:-$LOCAL_IP}
NG_PORT=${RTPENGINE_NG_PORT:-2223}
PORT_MIN=${RTPENGINE_PORT_MIN:-30000}
PORT_MAX=${RTPENGINE_PORT_MAX:-30100}
for port in "$NG_PORT" "$PORT_MIN" "$PORT_MAX"; do
    case $port in
        '' | *[!0-9]*)
            echo "rtpengine-entrypoint: ports must be decimal numbers" >&2
            exit 1
            ;;
    esac
done
if [ "$PORT_MIN" -ge "$PORT_MAX" ]; then
    echo "rtpengine-entrypoint: RTPENGINE_PORT_MIN must be lower than RTPENGINE_PORT_MAX" >&2
    exit 1
fi
exec rtpengine \
    --foreground \
    --log-stderr \
    --log-level="${RTPENGINE_LOG_LEVEL:-6}" \
    --table=-1 \
    --interface="${LOCAL_IP}!${ADVERTISE}" \
    --listen-ng="0.0.0.0:${NG_PORT}" \
    --port-min="${PORT_MIN}" \
    --port-max="${PORT_MAX}" \
    --delete-delay=0 \
    "$@"
