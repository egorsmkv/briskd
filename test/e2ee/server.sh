#!/bin/sh
# Build ircd into a private directory (the checkout is mounted read-only) and
# run it in the foreground with the given configuration.
set -eu
export REBAR_BASE_DIR=/tmp/build
rebar3 compile
exec env IRCD_CONFIG="$1" erl -noshell -noinput -pa /tmp/build/default/lib/*/ebin \
    -eval '{ok, _} = application:ensure_all_started(ircd).'
