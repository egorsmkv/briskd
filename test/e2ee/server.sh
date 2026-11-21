#!/bin/sh
# Build briskd into a private directory (the checkout is mounted read-only) and
# run it in the foreground with the given configuration.
set -eu
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: server.sh <config.json>" >&2
    exit 2
fi
export REBAR_BASE_DIR=/tmp/build
rebar3 compile
# -pa takes every following directory until the next flag, so the shell glob
# adds each dependency's ebin, not only briskd's.
# shellcheck disable=SC2086
exec env BRISKD_CONFIG="$1" erl -noshell -noinput -pa /tmp/build/default/lib/*/ebin \
    -eval '{ok, _} = application:ensure_all_started(briskd).'
