#!/bin/sh
# Bind media on the container address and advertise RTPFLUX_ADVERTISE
# (default: the container address) in SDP. The NG control socket listens on
# the container address, port RTPFLUX_NG_PORT (UDP). Media uses
# RTPFLUX_PORT_MIN..RTPFLUX_PORT_MAX (RTPFLUX_PORT_MIN must be even). The
# configuration is written to a temporary file and checked with
# `rtpflux --check` before the relay starts.
set -eu
# `hostname -i` prints every address. The first one is the address media
# binds to. A pipeline would hide a failure from hostname, so an empty
# result is checked afterwards.
LOCAL_IP=$(hostname -i 2>/dev/null | awk 'NF { print $1; exit }' || true)
if [ -z "$LOCAL_IP" ]; then
    echo "rtpflux-entrypoint: hostname -i did not return an address" >&2
    exit 1
fi
ADVERTISE=${RTPFLUX_ADVERTISE:-$LOCAL_IP}
NG_PORT=${RTPFLUX_NG_PORT:-2223}
PORT_MIN=${RTPFLUX_PORT_MIN:-30000}
PORT_MAX=${RTPFLUX_PORT_MAX:-30100}
LOG_LEVEL=${RTPFLUX_LOG_LEVEL:-info}
for port in "$NG_PORT" "$PORT_MIN" "$PORT_MAX"; do
    case $port in
        '' | *[!0-9]*)
            echo "rtpflux-entrypoint: ports must be decimal numbers" >&2
            exit 1
            ;;
    esac
done
if [ "$PORT_MIN" -ge "$PORT_MAX" ]; then
    echo "rtpflux-entrypoint: RTPFLUX_PORT_MIN must be lower than RTPFLUX_PORT_MAX" >&2
    exit 1
fi
if [ $((PORT_MIN % 2)) -ne 0 ]; then
    echo "rtpflux-entrypoint: RTPFLUX_PORT_MIN must be even (RTP uses even ports)" >&2
    exit 1
fi
case $ADVERTISE in
    '' | *[!0-9A-Fa-f.:]*)
        echo "rtpflux-entrypoint: RTPFLUX_ADVERTISE must be an IP address" >&2
        exit 1
        ;;
esac
case $LOG_LEVEL in
    error | warn | info | debug | trace) ;;
    *)
        echo "rtpflux-entrypoint: RTPFLUX_LOG_LEVEL must be error, warn, info, debug or trace" >&2
        exit 1
        ;;
esac
# Each call holds up to four RTP/RTCP port pairs here: two legs, each with an
# audio and, without BUNDLE, a video transport. rtpflux refuses a range that
# cannot serve sessions.max calls.
PAIRS=$(((PORT_MAX - PORT_MIN + 1) / 2))
SESSIONS=$((PAIRS / 4))
if [ "$SESSIONS" -lt 1 ]; then
    echo "rtpflux-entrypoint: the port range is too small for one call" >&2
    exit 1
fi
CONFIG=$(mktemp /tmp/rtpflux.XXXXXX.toml)
cat >"$CONFIG" <<TOML
# The NG protocol has no authentication: listen on the container address
# only, which the compose network keeps private to the development stack.
[control]
listen = ["${LOCAL_IP}:${NG_PORT}"]

[[interface]]
name = "default"
address = "${LOCAL_IP}"
advertise = "${ADVERTISE}"

[ports]
min = ${PORT_MIN}
max = ${PORT_MAX}

[sessions]
max = ${SESSIONS}

# Docker's default seccomp profile refuses io_uring.
[runtime]
receive = "recvmmsg"

[log]
level = "${LOG_LEVEL}"
TOML
rtpflux --check -c "$CONFIG"
exec rtpflux -c "$CONFIG" "$@"
