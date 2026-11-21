#!/bin/sh
# Build the WebUI assets and briskd from a private copy of the checkout (it is
# mounted read-only and the assets are generated), then run briskd with the
# given configuration in the foreground.
set -eu
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: server.sh <config.json>" >&2
    exit 2
fi
mkdir -p /tmp/src
# Two tar steps so a failure to read the checkout is not hidden by the pipe.
# /bin/sh here is dash, which has no pipefail. Generated and VCS trees are
# left behind; the WebUI build writes its own assets.
tar -C /workspace \
    --exclude=./.git \
    --exclude=./_build \
    --exclude=./doc \
    --exclude=./bench/.venv \
    --exclude=./search/target \
    --exclude=./webui/node_modules \
    --exclude=./priv/webui/assets \
    -cf /tmp/src.tar .
tar -C /tmp/src -xf /tmp/src.tar
rm -f /tmp/src.tar
cd /tmp/src/webui
DENO_DIR=/tmp/deno deno task build
cd /tmp/src
export REBAR_BASE_DIR=/tmp/build
rebar3 compile
# -pa takes every following directory until the next flag.
# shellcheck disable=SC2086
exec env BRISKD_CONFIG="$1" erl -noshell -noinput -pa /tmp/build/default/lib/*/ebin \
    -eval '{ok, _} = application:ensure_all_started(briskd).'
