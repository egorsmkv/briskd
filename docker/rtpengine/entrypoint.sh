#!/bin/sh
# Bind media on the container address and advertise RTPENGINE_ADVERTISE
# (default: the container address) in SDP. The NG control port listens on
# RTPENGINE_NG_PORT (UDP). Media uses RTPENGINE_PORT_MIN..RTPENGINE_PORT_MAX.
set -eu
LOCAL_IP=$(hostname -i | awk '{print $1}')
ADVERTISE=${RTPENGINE_ADVERTISE:-$LOCAL_IP}
exec rtpengine \
    --foreground \
    --log-stderr \
    --log-level="${RTPENGINE_LOG_LEVEL:-6}" \
    --table=-1 \
    --interface="${LOCAL_IP}!${ADVERTISE}" \
    --listen-ng="0.0.0.0:${RTPENGINE_NG_PORT:-2223}" \
    --port-min="${RTPENGINE_PORT_MIN:-30000}" \
    --port-max="${RTPENGINE_PORT_MAX:-30100}" \
    --delete-delay=0 \
    "$@"
