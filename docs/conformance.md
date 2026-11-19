# IRCv3 conformance with irctest

`test/irctest/ircd_controller.py` runs [irctest](https://github.com/progval/irctest)
against this server, starting a fresh server for every test inside a helper
container with `test/irctest/ircd.json`:

```sh
docker compose -f docker-compose.dev.yml run -d --rm -p 6667:6667 \
    --name ircd-irctest ircd-dev sleep infinity
docker exec -w /workspace ircd-irctest rebar3 compile
cd /path/to/irctest
PYTHONPATH=/path/to/irc-server/test/irctest IRCTEST_SERVER_HOSTNAME=localhost \
    IRCTEST_SERVER_PORT=6667 pytest --controller ircd_controller \
    -m "not implementation-specific and not deprecated"
```

The controller stands in for services: it links a minimal
`My.Little.Services` peer over RFC 2813 and provisions test accounts with
`ACCOUNTSYNC`. `test/irctest/ircd.json` enables the opt-in `multiclient` and
`account_rejoin` features, a 30-character `nicklen`, and no nickname delay,
because irctest reuses nicknames between tests. With irctest's standard
selection (`-m "not implementation-specific and not deprecated"`) all 491
applicable tests pass.
