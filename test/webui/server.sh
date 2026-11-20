#!/bin/sh
# Build the WebUI assets and ircd from a private copy of the checkout (it is
# mounted read-only and the assets are generated), then run ircd with the
# given configuration in the foreground.
set -eu
mkdir -p /tmp/src
tar -C /workspace --exclude=./_build --exclude=./webui/node_modules \
    --exclude=./priv/webui/assets -cf - . | tar -C /tmp/src -xf -
cd /tmp/src/webui
DENO_DIR=/tmp/deno deno task build >/dev/null
cd /tmp/src
export REBAR_BASE_DIR=/tmp/build
rebar3 compile
exec env IRCD_CONFIG="$1" erl -noshell -noinput -pa /tmp/build/default/lib/*/ebin \
    -eval '{ok, _} = application:ensure_all_started(ircd).'
