default:
    @just --list

# Build WebUI TypeScript and Sass assets with Deno.
build-webui:
    cd webui && deno task build

# Type-check WebUI TypeScript sources with Deno.
check-webui:
    cd webui && deno task check

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

# Lint Erlang sources with ELP; fails on any diagnostic. Dependencies'
# headers under _build are not this project's code, so only these paths run.
lint:
    elp lint --no-connect --path src
    elp lint --no-connect --path test
    elp lint --no-connect --path include

# Type-check src/ and test/ with eqWAlizer (ELP); fails on any finding.
eqwalize:
    elp eqwalize-all --no-connect --bail-on-error

# Run the Erlang unit test suite (the web UI tests fetch the built assets).
test: build-webui
    rebar3 eunit

# Run the unit tests with line coverage; fail below 90% total.
cover: build-webui
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
