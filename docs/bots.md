# AI assistant bots

The server can run AI assistant bots defined in the configuration file. Each
bot is an ordinary IRC user (nick, `+B` bot mode, channel membership) that
answers questions through an **OpenAI-compatible** chat completions API:
OpenAI, OpenRouter, Groq, Together, Mistral, vLLM, llama.cpp server, Ollama
(`/v1`), LM Studio, LiteLLM, and similar.

Bots are a server extension, not part of RFC 1459/2812 or IRCv3. On the wire
they behave like local clients: they register with `NICK`/`USER`, set user
mode `+B` (advertised as `BOT=B`, so their messages carry the IRCv3 `bot`
tag), `JOIN` their channels, and reply with `PRIVMSG`.

## Configuration

Two top-level keys: `ai_providers` names the endpoints, and `bots` lists the
assistants.

```json
{
  "ai_providers": {
    "openai": {
      "base_url": "https://api.openai.com/v1",
      "api_key_env": "OPENAI_API_KEY",
      "model": "gpt-4o-mini",
      "timeout": 60
    },
    "local": {
      "base_url": "http://127.0.0.1:11434/v1",
      "model": "llama3.1"
    }
  },
  "bots": [
    {
      "nick": "helper",
      "realname": "AI assistant (answers are machine-generated)",
      "provider": "openai",
      "system_prompt": "You are a friendly helper for the #lobby community. Answer briefly.",
      "channels": ["#lobby", "#help"]
    },
    {
      "nick": "coder",
      "provider": "local",
      "model": "qwen2.5-coder",
      "system_prompt_file": "config/prompts/coder.txt",
      "channels": ["#dev"],
      "context": "channel",
      "history_lines": 30,
      "direct_messages": false
    }
  ]
}
```

### `ai_providers`

An object mapping a provider name (`[A-Za-z0-9_-]`, 1–32 characters, at most
20 providers) to:

| Key | Default | Description |
| --- | --- | --- |
| `base_url` | required | `http://` or `https://` URL of the API root; `/chat/completions` is appended. A trailing `/` is ignored |
| `api_key` | none | Bearer token sent as `Authorization: Bearer …` |
| `api_key_env` | none | Name of an environment variable holding the key, read at startup. Use this instead of `api_key` to keep secrets out of the file. When the variable is unset or empty, the server still starts but the bots using this provider are not started, and a `bot_disabled` warning names each bot and the variable |
| `model` | required | Default model name for bots using this provider |
| `timeout` | `60` | Seconds to wait for a reply (1..600) |

Set at most one of `api_key` and `api_key_env`; with neither, no
`Authorization` header is sent (typical for a local server). The key is never
logged, never included in configuration errors, and is redacted from process
status output.

### `bots`

A list of at most 50 bots:

| Key | Default | Description |
| --- | --- | --- |
| `nick` | required | Nickname; must be valid under `nicklen`. Nicknames are unique (RFC 1459 case mapping) |
| `user` | `bot` | Username shown in `nick!user@host`; the host is the server `name` |
| `realname` | `AI assistant` | Real name shown in `WHOIS`. Saying that answers are generated is recommended |
| `provider` | required | A name from `ai_providers` |
| `model` | provider's | Model override for this bot |
| `system_prompt` | empty | System prompt text (at most 16 KiB) |
| `system_prompt_file` | none | File holding the system prompt, read at startup (relative to the working directory). Use instead of `system_prompt` |
| `channels` | `[]` | Channels to join at startup (at most 50). An empty list makes a private-message-only bot |
| `respond_to` | `mention` | `mention`: answer channel messages that address the bot. `all`: answer every channel message (use with care) |
| `direct_messages` | `true` | Answer private messages. When `false`, a private message gets a `NOTICE` saying the bot only answers in channels |
| `context` | `conversation` | What the model sees as history. `conversation`: only questions put to the bot and its answers. `channel`: the recent channel lines as well, whoever wrote them |
| `history_lines` | `20` | Turns of history kept per channel or private conversation (0..100; 0 sends no history) |
| `max_tokens` | `512` | `max_tokens` sent with each request (1..32768) |
| `temperature` | `0.7` | `temperature` sent with each request (0..2) |
| `max_reply_lines` | `6` | Most IRC lines in one answer (1..30); a longer answer is cut and ends with `[…]` |
| `requests_per_minute` | `10` | Requests the bot may make per minute (1..600), as a token bucket |

Invalid values stop startup with a configuration error naming the bot and the
key, like other settings.

## Behavior

**Addressing.** With `respond_to: mention`, a channel message addresses the
bot when it starts with the nickname followed by `:` or `,` (`helper: what is
a netsplit?`), or contains `@helper` as a word. Matching uses the RFC 1459
case mapping. The addressing prefix is removed before the question is sent.

**Replies.** A message carrying `+draft/reply` (IRCv3 reply client tag) that
points at one of the bot's own messages is answered too, without a mention.
The bot learns its messages' `msgid`s through `echo-message` and remembers
its last 500 lines, so a reply to an older answer is recognized; the model
is told which of its messages the user replied to. In both cases the answer's
first line carries `+draft/reply` pointing at the question, so clients that
support replies show it threaded.

**Answers.** In a channel the first line starts with the asker's nickname
(`alice: …`). Each line is sized so the delivered line stays within the
512-octet limit, multi-byte characters are never split, blank lines are
dropped, and control characters from the model are removed. While a request
runs, the bot sends `+typing=active` `TAGMSG`s, which clients with the
`typing` feature show as a typing indicator.

**Never answered.** `NOTICE`s (RFC 2812 3.3.2: automatic replies must never be
sent in response to a `NOTICE`), messages carrying the `bot` tag (so two bots
cannot talk to each other indefinitely), the bot's own messages, and CTCP
requests. `ACTION` (`/me`) lines are kept as channel context but do not
trigger an answer.

**Limits.** One request at a time per channel or private conversation, at most
4 at once per bot, and `requests_per_minute` overall. A refused question gets
a `NOTICE` to the asker ("still answering", "busy", or "too many requests").
A failed or timed-out request gets a `NOTICE` saying no answer is available,
and a `bot_request_failed` warning is logged with the bot's nickname and the
failure kind (for example `{http_status, 429}` or `timeout`).

**Membership.** If a bot is kicked, it rejoins after 30 seconds. If an
operator `KILL`s it, it registers again after 15 seconds. If its nickname is
taken, it tries `nick_` and `nick__`, then retries the configured nickname
every minute. A channel that refuses the join (`+i`, `+k`, `+l`, ban) is
logged as `bot_join_refused`.

## Privacy and data handling

A bot sends text to the configured provider, which is usually a third-party
service. Decide what is acceptable for your users:

- With `context: conversation` (the default), only messages that address the
  bot, plus its own earlier answers, are sent.
- With `context: channel` or `respond_to: all`, **every recent line in the
  channel** is sent to the provider when the bot answers. Tell the channel's
  users, for example in the topic.
- Private messages to the bot are sent to the provider.
- Conversation memory lives only in the bot process, is capped by
  `history_lines` (and 100 private conversations per bot), and is lost on
  restart. The server never logs message text or prompts.
- Use an `https://` `base_url` for remote providers. Certificates are verified
  (hostname checking included) by the HTTP client's defaults; redirects are
  not followed, and replies are capped at 1 MiB.

## Operations

- Bots are created at startup. `REHASH` does not add, remove, or change bots;
  restart the server after editing `ai_providers` or `bots`.
- Bots do not count against `max_clients`. They are subject to the `flood`
  limits like other clients.
- Bots run under their own supervisor, started last. If bots keep crashing
  (more than 5 restarts in 60 seconds), the bot supervisor stops and stays
  down, leaving listeners and clients unaffected. Restart the server to bring
  bots back.
- Log events: `bot_disabled`, `bot_registered`, `bot_disconnected`, `bot_nick_unavailable`,
  `bot_join_refused`, `bot_rate_limited`, `bot_request_failed`.
