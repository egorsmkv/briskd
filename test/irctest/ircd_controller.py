"""irctest controller for this Erlang ircd.

irctest expects a fresh server for every test. This controller starts one
ircd per test inside a long-running helper container (the development image
with the checkout mounted at /workspace and port 6667 published), each with
an empty Mnesia directory and `test/irctest/ircd.json`:

    docker compose -f docker-compose.dev.yml run -d --rm -p 6667:6667 \
        --name ircd-irctest ircd-dev sleep infinity
    docker exec ircd-irctest rebar3 compile
    PYTHONPATH=test/irctest IRCTEST_SERVER_HOSTNAME=localhost \
        IRCTEST_SERVER_PORT=6667 pytest --controller ircd_controller \
        -m 'IRCv3 and not implementation-specific'

There is no services daemon: accounts are created with the server's own
draft/account-registration REGISTER command.
"""

import json
import os
import socket
import subprocess
import time
from typing import Optional, Type

from irctest.controllers.external_server import ExternalServerController

CONTAINER = os.environ.get("IRCTEST_IRCD_CONTAINER", "ircd-irctest")
# The previous test's server is stopped through its PID file (matching on the
# command line would also match this shell), then a fresh one starts with the
# per-test configuration written by run().
START = (
    "if [ -f /tmp/ircd-irctest.pid ]; then kill $(cat /tmp/ircd-irctest.pid) 2>/dev/null; "
    "P=$(cat /tmp/ircd-irctest.pid); "
    "while [ -e /proc/$P ] && ! grep -q '^State:.*Z' /proc/$P/status 2>/dev/null; "
    "do sleep 0.05; done; fi; "
    "rm -rf /tmp/ircd-irctest-db; "
    "IRCD_CONFIG=/tmp/ircd-irctest.json nohup sh -c 'echo $$ > /tmp/ircd-irctest.pid; "
    "exec erl -noshell -noinput -pa _build/default/lib/*/ebin "
    "-eval \"{ok, _} = application:ensure_all_started(ircd).\"' "
    ">/tmp/ircd-irctest.log 2>&1 &"
)

BASE_CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ircd.json")


class IrcdController(ExternalServerController):
    software_name = "ircd (Erlang/OTP)"
    supported_sasl_mechanisms = {"PLAIN", "EXTERNAL", "SCRAM-SHA-256"}
    supports_sts = False

    def run(self, hostname, port, *, password, ssl, run_services, faketime,
            websocket_hostname, websocket_port) -> None:  # type: ignore
        super().run(
            hostname, port, password=password, ssl=ssl, run_services=run_services,
            faketime=faketime, websocket_hostname=websocket_hostname,
            websocket_port=websocket_port,
        )
        with open(BASE_CONFIG) as f:
            config = json.load(f)
        test_config = self.test_config
        config["account_registration_before_connect"] = (
            test_config.account_registration_before_connect
        )
        config["account_registration_email_required"] = (
            test_config.account_registration_requires_email
        )
        if password is not None:
            config["client_password"] = password
        subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "sh", "-c", "cat > /tmp/ircd-irctest.json"],
            input=json.dumps(config).encode(),
            check=True,
        )
        subprocess.run(
            ["docker", "exec", "-w", "/workspace", CONTAINER, "sh", "-c", START], check=True
        )
        self._wait_ready()

    def _wait_ready(self) -> None:
        hostname, port = self.get_hostname_and_port()
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                with socket.create_connection((hostname, port), timeout=1) as sock:
                    sock.sendall(b"PING ready\r\n")
                    sock.settimeout(2)
                    if sock.recv(1024):
                        return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError("ircd did not start")

    def wait_for_services(self) -> None:
        pass

    def registerUser(self, case, username: str, password: Optional[str] = None) -> None:  # type: ignore
        hostname, port = self.get_hostname_and_port()
        nick = "reg%d" % (time.monotonic_ns() % 100000)
        with socket.create_connection((hostname, port), timeout=10) as sock:
            sock.sendall(
                (
                    "CAP LS 302\r\nCAP REQ draft/account-registration\r\n"
                    "NICK %s\r\nUSER reg * * :reg\r\nCAP END\r\n"
                    "REGISTER %s * %s\r\nQUIT\r\n" % (nick, username, password or "")
                ).encode()
            )
            data = b""
            while b"REGISTER SUCCESS" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise AssertionError("account registration failed: %r" % data[-300:])
                data += chunk


def get_irctest_controller_class() -> Type[IrcdController]:
    return IrcdController
