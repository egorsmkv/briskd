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

# Run Dialyzer (mnesia is added to the PLT in rebar.config).
dialyzer:
    rebar3 dialyzer

# Run the Erlang unit test suite.
test:
    rebar3 eunit

# Run the unit tests with line coverage; fail below 90% total.
cover:
    rebar3 eunit --cover
    rebar3 cover --verbose --min_coverage 90

# Build the HTML documentation into doc/ with ex_doc.
docs:
    rebar3 ex_doc

# Fetch dependencies and formatter plugin.
deps:
    rebar3 get-deps

# Remove compiled build artifacts.
clean:
    rebar3 clean
