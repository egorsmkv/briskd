default:
    @just --list

# Compile the application and dependencies.
build:
    rebar3 compile

# Build a packaged release that includes ERTS.
release:
    rebar3 as prod release

# Format Erlang source files with erlfmt.
format:
    rebar3 fmt

# Fail if Erlang source files need formatting.
format-check:
    rebar3 fmt --check

# Start the server with config/ircd.json or the IRCD_CONFIG override.
run:
    rebar3 shell

# Start the server with a selected JSON configuration file.
run-config config:
    IRCD_CONFIG={{config}} rebar3 shell

# Check for undefined and deprecated calls with xref.
xref:
    rebar3 xref

# Run the Erlang unit test suite.
test:
    rebar3 eunit

# Run the unit tests with line coverage; fail below 90% total.
cover:
    rebar3 eunit --cover
    rebar3 cover --verbose --min_coverage 90

# Fetch dependencies and formatter plugin.
deps:
    rebar3 get-deps

# Remove compiled build artifacts.
clean:
    rebar3 clean
