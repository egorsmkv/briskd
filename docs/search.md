# Message search

Optional full-text search over the messages the server keeps in its stored
history, offered to clients as the vendor capability
`egorsmkv.github.io/search` and used by WebIRC's search dialog. No IRCv3
specification for search exists; this is a server-specific extension.

## How it works

```text
clients ──SEARCH──▶ ircd ──POST /search──▶ ircd-search (Tantivy index)
                     │  ◀──── ids ───────
                     │
          stored history (Mnesia) ──POST /index──▶ (mirrored)
```

- **ircd-search** (`search/` in this repository, Rust) holds a
  [Tantivy](https://github.com/quickwit-oss/tantivy) index. It is an
  HTTP/JSON service: `POST /index` applies index changes, `POST /search` runs a
  query restricted to the conversations ircd names, and `GET /health` reports
  readiness and the document count.
- **The index mirrors stored history.** `ircd_search` forwards every history
  change: a stored `PRIVMSG` or `NOTICE` is added, a message trimmed by
  `history_limit` is removed, and a redaction, edit, account erasure ("Delete
  my data"), or destroyed channel removes the conversation and indexes what
  history keeps of it. Searches reach exactly as far back as `CHATHISTORY`.
- **Not indexed:** end-to-end encrypted messages (the server only sees
  ciphertext), `TAGMSG` (reactions, typing), events (joins, parts, modes),
  and anything history does not keep (`chathistory: false`, messages between
  users who are not logged in).
- **The index holds no readable text.** Message bodies are tokenized for
  matching but not stored, and a search returns only message ids. ircd loads
  each result from its own history, so a message deleted after it was indexed
  is never shown.
- **ircd decides access.** The service never sees who is searching; ircd
  sends the list of conversations the user may read, and checks it again when
  the results arrive.

Each server indexes its own history: on linked servers, run one service per
server.

## Protocol

The capability `egorsmkv.github.io/search` is offered when `search` is
configured. Its value is `limit=<max_results>`.

```text
SEARCH <target> <limit> [timestamp=<time>] :<query>
```

| Parameter | Meaning |
| --- | --- |
| `<target>` | A channel you are a member of; a nickname or account, for your direct conversation with it (you must be logged in); or `*`, for every channel you are in and every direct conversation of your account |
| `<limit>` | Results wanted, at least 1; lowered to the capability's `limit` |
| `timestamp=<time>` | Optional RFC 3339 time: only messages older than it (for paging). `*` in its place means no bound |
| `<query>` | 1 to 300 bytes: words (all must match, any case and script), `"a phrase"`, `prefix*`, `-excluded`, `a OR b` |

Results arrive newest first in a batch:

```text
:irc.dev BATCH +r1 egorsmkv.github.io/search #dev 2
@batch=r1;msgid=...;time=... :bob!b@host PRIVMSG #dev :the deploy finished
@batch=r1;msgid=...;time=... :ann!a@host PRIVMSG #dev :deploy at 5?
:irc.dev BATCH -r1
```

The batch parameters are the target and the total number of matches. Each
result is the stored message replayed as `CHATHISTORY` replays it, with its
`msgid` and `time` tags, addressed to its channel or, for a direct message,
to its stored target. Use `CHATHISTORY AROUND <target> msgid=<id>` to show a
result in context. To page back, repeat the search with the `time` of the
last result as `timestamp=`.

Errors are standard replies:

| Reply | When |
| --- | --- |
| `FAIL SEARCH NEED_MORE_PARAMS` | Fewer than three parameters |
| `FAIL SEARCH INVALID_PARAMS <param>` | A bad limit, timestamp, or an empty or over-long query (`query`) |
| `FAIL SEARCH INVALID_TARGET <target>` | Not a channel you are in, or a nickname while not logged in |
| `FAIL SEARCH TEMPORARILY_UNAVAILABLE <target>` | The service did not answer in time, or the server is busy |
| `421` | `search` is not configured |

Searches run outside ircd's state process (in a bounded `ircd_deferred`
worker), so a slow service does not delay chat. When 24 of the 32 workers are
busy, `SEARCH` fails at once with `TEMPORARILY_UNAVAILABLE`, keeping room for
logins, which share them.

## WebIRC

When the server offers search, the conversation header shows a search button
(also Ctrl+K or ⌘K, and `/search <words>`). The dialog searches the open
conversation or every conversation, highlights the matched words, and pages
back with "Load older results". Choosing a result opens its conversation and
scrolls to the message, fetching the history around it when needed.

## Configuration

```json
"search": {
  "url": "http://ircd-search:7700",
  "token_env": "IRCD_SEARCH_TOKEN",
  "timeout": 3000,
  "max_results": 50
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `url` | required | Base URL of ircd-search (`http://` or `https://`) |
| `token` / `token_env` | none | Bearer token the service requires, inline or from an environment variable (the server refuses to start when the variable is unset) |
| `timeout` | `3000` | Milliseconds to wait for the service (100..60000) |
| `max_results` | `50` | Most results per `SEARCH` (1..200) |

`search: null` (the default) disables the feature. Adding or removing it
takes a restart.

The service reads its environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SEARCH_ADDR` | `0.0.0.0:7700` | Listen address |
| `SEARCH_DIR` | `/data/index` | Index directory (a volume) |
| `SEARCH_TOKEN` | none | When set, every request must carry `Authorization: Bearer <token>` |

## Operations

- **Rebuilds.** When ircd starts, and whenever the service answers again after
  a failed request, ircd clears the index and sends every stored message
  (about 3.5 seconds for 100,000 messages in the development environment).
  During a rebuild, searches return what has been indexed so far. Index
  changes are queued meanwhile (at most 100,000; past that the queue is
  dropped and another rebuild follows).
- **Outages.** Chat is unaffected. `SEARCH` answers
  `TEMPORARILY_UNAVAILABLE`, ircd logs `search_unavailable` once and retries
  every 5 to 60 seconds, then logs `search_ready` after the rebuild.
- **Backups.** The index is derived data: losing it costs a rebuild, not
  messages. Back up Mnesia (see [Mnesia operations](mnesia.md)), not the
  index.
- **Security.** Keep the service on a private network and set a token. It
  holds the words of every stored message, so treat its volume like the
  Mnesia directory.

## Running it

The development environment runs one service per server (`ircd-search` and
`ircd-search2` in `docker-compose.dev.yml`). For production, add the service
next to ircd and give both the same token:

```yaml
services:
  ircd:
    environment:
      IRCD_SEARCH_TOKEN: ${IRCD_SEARCH_TOKEN}
  search:
    build:
      context: search
    restart: unless-stopped
    environment:
      SEARCH_TOKEN: ${IRCD_SEARCH_TOKEN}
    volumes:
      - search-data:/data
volumes:
  search-data:
```

and set `"search": {"url": "http://search:7700", "token_env":
"IRCD_SEARCH_TOKEN"}` in the server's configuration.

To build and test the service alone:

```sh
cd search
cargo test
cargo clippy --all-targets -- -D warnings
docker build -t ircd-search .
```
