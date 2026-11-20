# Development

## Docker development environment

Docker Compose provides OTP 29, Rebar3, and `just`, and mounts the checkout at
`/workspace`. The container reads its environment from `.dev.env`, which is
not committed; create it once from the example:

```sh
cp .dev.env.example .dev.env
docker compose -f docker-compose.dev.yml up --build
```

Set `OPENAI_API_KEY` in `.dev.env` to enable the `helper` AI bot from
`config/ircd.dev.json`. When it is empty the server starts without that bot
(see [AI assistant bots](bots.md)).

The development server is available at `localhost:6667`, and IRC over
WebSocket at `ws://localhost:8080`. To run the container
in the background, add `-d`; then run project commands inside it, for example:

```sh
docker compose -f docker-compose.dev.yml exec -T ircd-dev just build
docker compose -f docker-compose.dev.yml exec -T ircd-dev just format-check
```

Stop the container with `docker compose -f docker-compose.dev.yml down`. The
Rebar3 cache and development database persist in named volumes. Use `down -v`
to remove those volumes and their contents.

## Project commands

If `just` is installed, `just --list` shows the available commands:

| Command | Action |
| --- | --- |
| `just build` | Compile the application and dependencies |
| `just release` | Build a packaged production release with ERTS included |
| `just run` | Start with `config/ircd.json` |
| `just run-config path/to/file.json` | Start with a selected configuration |
| `just format` | Format Erlang source with erlfmt |
| `just format-check` | Check Erlang formatting |
| `just xref` | Check for undefined and deprecated calls |
| `just dialyzer` | Run Dialyzer with strict warnings |
| `just lint` | Lint `src/`, `test/`, and `include/` with ELP; fails on any diagnostic |
| `just eqwalize` | Type-check `src/` and `test/` with eqWAlizer (ELP); fails on any finding |
| `just test` | Run the EUnit suite, including the two-server interop test |
| `just test-webui` | Check formatting, type-check, lint, and unit-test the WebUI (Deno), including the theme contrast tests |
| `just cover` | Run the suite with coverage; fail below 90% |
| `just docs` | Build the HTML documentation into `doc/` |
| `just deps` | Fetch Rebar3 dependencies |
| `just clean` | Remove compiled build artifacts |

## Static analysis with ELP

The development image includes [ELP](https://github.com/WhatsApp/erlang-language-platform)
(WhatsApp's Erlang Language Platform), pinned in the `Dockerfile` by release
tag and checksum. It adds checks that the compiler, xref, and Dialyzer do not
make: more than 90 lints (unused includes, redundant allocations such as
`maps:find/2` where a map pattern suffices, map generators instead of
`maps:to_list/1`, boolean precedence, risky atom creation, and more; see the
[error index](https://whatsapp.github.io/erlang-language-platform/docs/erlang-error-index/)),
the eqWAlizer type checker, and a language server for editors.

- `just lint` runs in CI with the format check and the tests. It lints this
  project's paths only: the headers of dependencies under `_build` are not
  this project's code and do not lint cleanly on their own.
- `.elp_lint.toml` configures the lints. It turns off W0083 (types in
  headers), since shared record types live in `include/*.hrl` by design.
- Suppress a single occurrence with a reason, on the line above it:
  `% elp:ignore W0020 (record_info/2 use)`. Prefer fixing the code.
- Many lints have fixes. Apply one lint at a time, then build and test,
  because a fix can be wrong: W0020 does not see includes used only by
  `record_info/2`, and removing them breaks the build.

  ```sh
  docker compose -f docker-compose.dev.yml exec -T ircd-dev \
      elp lint --no-connect --path src --diagnostic-filter W0032 --apply-fix --one-shot
  ```

- `just eqwalize` type-checks `src/` and `test/` with eqWAlizer and runs in CI. It is
  stricter than Dialyzer: an expression whose type is wider than the spec
  expects is an error, so `term()` must be narrowed before use. Tests are
  checked too: socket data is matched as `{ok, <<_/binary>> = Data}`, and a
  test of bad input passes a value of the right type that is still invalid
  (for example `{0, 0, 0, 0, 0, 0, 0, -1}` as an address), or calls a
  function whose spec accepts `term()` because it rejects anything else.
- Keep the code typed rather than suppressed:
  - Read the running configuration with `ircd_config:current/0` (typed as
    `ircd_config:config()`), or `current_or_empty/0` where code also runs
    before the server starts; write it only with `ircd_config:store/1`.
  - Per-connection state goes through `ircd_conn:get/2,3` and `put/3`, whose
    specs give each key its value type; add a new key to `ircd_conn:key()`
    and to those specs.
  - Bind a Mnesia row as `[#client{} = Client]`, not `[Client]`, and list a
    table's keys with `ircd_state:table_keys/1`.
  - Narrow untyped input (decoded JSON, `gen_tcp:recv/3` data, ETS rows)
    with a guard (`is_binary/1`, `is_integer/1`) where it enters.
- An `% eqwalizer:ignore` needs a reason and, since ELP flags it (W0074), an
  `% elp:ignore W0074 (reason)` above it. Two remain: `ircd_wire:retain/1`
  (a generic identity eqWAlizer cannot express) and the STARTTLS
  `ssl:handshake/3` call (its option types are not exported by `ssl`).

Editors: install the "Erlang Language Platform" extension in VS Code
(`erlang-language-platform.erlang-language-platform`), or point an LSP client
at `elp server` (Neovim: `:MasonInstall elp` and lspconfig's `elp`; Emacs:
`("elp" "server")` for eglot or lsp-mode). The editor then shows the same
lints, eqWAlizer types, go-to-definition, and references. A local ELP binary
must match OTP 29: use the `otp-29.1` release asset.

## WebUI code layout

The browser pages are one Preact single-page app (TypeScript and TSX under
`webui/src`), bundled by `webui/build.ts` (esbuild, with a lazily loaded
chunk per page) into `priv/webui/assets`. Those assets are generated and
not committed (`.gitignore`): `just build-webui` writes them, and runs on its
own when the development container starts and before `just test`; the
`webui` stage of `Dockerfile.prod` builds them for the production image.
`deno task check`, `deno task lint`, `deno task test`, and `deno task build`
run in `webui/` (inside the development container, which has Deno).

`webui/src/app/` is the app: `main.tsx` mounts `App.tsx`, which picks the
page for the path (`routes.ts`), loads its chunk and stylesheet, and keeps
the chat mounted while other pages are shown, so its connection survives.
`router.ts` handles in-app links and back/forward; `config.ts` reads the
settings the server puts in the HTML shell (`priv/webui/app.html`).

| Path | Contents |
| --- | --- |
| `app/pages/auth/` | Sign-up, account verification, and password recovery pages; `app/components/auth.tsx` holds their card, notice, field, and ALTCHA components |
| `app/pages/admin/` | The admin panel: tabs, tables, dialogs, toasts, and a typed store over `/api/overview`, `/api/media`, `/api/action` |
| `app/pages/webirc/` | The chat page: typed markup in `view/`; `webirc/boot.ts` then starts the WebIRC controllers below in a fixed order |

| Module | Contents |
| --- | --- |
| `state.ts` | Mutable session state as one object `S` (`S.ws`, `S.myNick`, `S.activeBuf`, ...) and the conversations map |
| `types.ts`, `constants.ts`, `util.ts`, `parse.ts` | Shared types, IRCv3 tags and limits, small helpers, IRC line parsing |
| `caps.ts`, `users.ts` | Negotiated capabilities and ISUPPORT; known users, presence, MONITOR, read markers, metadata |
| `connection.ts` | WebSocket, heartbeat, automatic reconnection |
| `handler.ts`, `irc/*.ts` | Incoming lines: preprocessing, then one handler per area (`cap`, `registration`, `channels`, `chat`, `replies`, `presence`, `numerics`) |
| `buffers.ts`, `sidebar.ts` | Conversations and adding lines; switching, conversation and member lists |
| `chat/list.ts`, `chat/scroll.ts`, `chat/policy.ts` | The open conversation: the windowed message list; scrolling (follow the newest line, keep the reader's place, unseen count, load earlier lines, per-conversation position, jump to a line); pure grouping and window rules |
| `chat/row.ts` and its parts | One message row built from `avatar.ts`, `meta.ts`, `body.ts`, `reply_ref.ts`, `reactions.ts`, `actions.ts` |
| `composer.ts`, `commands.ts`, `message_actions.ts`, `typing.ts` | The message box and multi-line sending; slash commands; replies, edits, reactions, redactions; typing indicators |
| `files.ts`, `voice.ts` | Uploads, attachments, code snippets; voice messages |
| `calls_ui.ts`, `call_settings_ui.ts`, `e2ee_ui.ts` | Call bar and dialogs; Settings → Calls; E2EE wiring and its tab |
| `settings.ts`, `session.ts`, `login.ts`, `modals.ts`, `layout.ts` | Settings dialog; saved session and URL paths; login and session start; topic, moderation and discovery dialogs; scroll button and touch gestures |
| `dm_cache.ts`, `dm_snapshot.ts` | Private conversations kept in the tab's `sessionStorage` across a page reload (the server keeps no private history for guests); logged-in users also get theirs back with `CHATHISTORY TARGETS` |

Modules export functions and read or assign shared state through `S`. A
module whose code runs on load puts it in `init()` rather than at the top
level, so the order in `webirc.ts` decides when listeners are attached. Pure
logic with unit tests lives in `webui/src/common/` and the call modules
(`calls.ts`, `call_settings.ts`, `hold_music.ts`).

### Look and themes

Colors, radii, and shadows are design tokens (CSS custom properties) in
`webui/styles/_tokens.scss`; components use the tokens, never literal
colors, so every theme follows. Light and dark are tuned by hand; the other
themes set the base palette and derive the rest (`color-mix()`). Nicknames
and avatars use eight palette slots (`--nick-N`, `--avatar-N`) that each
theme can retune, chosen by `nickClass()` in `webirc/util.ts`. Icons are the
line icons in `webui/src/common/icons.ts` (`iconEl()` for code that builds
the DOM, `<Icon>` in TSX), not emoji or text glyphs.

`src/common/theme_tokens_test.ts` (in `just test-webui`) checks, for light
and dark, that every text color has at least 4.5:1 contrast (WCAG 2.1 AA) on
each background it is used on, that both themes set the same tokens, and
that every `var(--name)` in the stylesheets is defined.

`test/webui/run` opens WebIRC in headless Chromium, in light and dark at
desktop and phone width, with other users talking in a channel. It fails on
a page error or on any probed text below 4.5:1 against what is actually
behind it, and leaves screenshots of the main views in `test/webui/shots/`
for review (CI keeps them as the `webirc-screenshots` artifact).

## End-to-end encryption tests

`test/e2ee/run` builds the server image, starts two linked servers, and runs
Python clients that do X3DH, the Double Ratchet, and Sender Keys against them
(`docker compose`, see [End-to-end encryption](e2ee.md)).

## Continuous integration

GitHub Actions builds the development image from the [Dockerfile](https://github.com/egorsmkv/irc-server/blob/main/Dockerfile)
and runs `just format-check`, `just lint` and `just eqwalize` (ELP),
`just test-webui`, and `just test` in that image. The image pins the same
OTP, Rebar3, `just`, Deno, and ELP versions as local development. Three more jobs run
`test/e2ee/run`, the end-to-end encryption tests on two linked servers,
`test/calls/run`, the voice call test with rtpengine and WebRTC clients, and
`test/webui/run`, WebIRC in a browser in light and dark themes.

## Building the documentation

API documentation is published at <https://egorsmkv.github.io/irc-server/>.
It is generated by [ex_doc](https://hexdocs.pm/ex_doc/) through the
`rebar3_ex_doc` plugin from the `-moduledoc` and `-doc` attributes in `src/`,
with the README, the guides in `docs/`, the roadmap, and the benchmark notes
as extra pages. Build it locally with `just docs` and open `doc/index.html`.

The `Docs` workflow (`.github/workflows/docs.yml`) builds the documentation on
every push and pull request and deploys it to GitHub Pages from `main`. Pages
must be enabled once with Settings → Pages → Source: GitHub Actions.
