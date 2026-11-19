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

import base64
import hashlib
import hmac
import json
import queue
import threading
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
        # A stand-in services server linked over RFC 2813 when the test asks
        # for services (irctest's LINKS tests expect My.Little.Services).
        config["server_links"] = [
            {
                "name": "My.Little.Services",
                "host": "127.0.0.1",
                "port": 1,
                "password": "servicespass",
                "tls": False,
            }
        ]
        self._run_services = run_services
        subprocess.run(
            ["docker", "exec", "-i", CONTAINER, "sh", "-c", "cat > /tmp/ircd-irctest.json"],
            input=json.dumps(config).encode(),
            check=True,
        )
        subprocess.run(
            ["docker", "exec", "-w", "/workspace", CONTAINER, "sh", "-c", START], check=True
        )
        self._wait_ready()
        self._services_sock = None
        if run_services:
            self._link_services()

    def _link_services(self) -> None:
        hostname, port = self.get_hostname_and_port()
        sock = socket.create_connection((hostname, port), timeout=10)
        sock.sendall(
            b"PASS servicespass 0210 |\r\n"
            b"SERVER My.Little.Services 1 1 :Services\r\n"
        )
        self._services_sock = sock

        def pump() -> None:
            buffer = b""
            try:
                while True:
                    data = sock.recv(4096)
                    if not data:
                        return
                    buffer += data
                    while b"\r\n" in buffer:
                        line, buffer = buffer.split(b"\r\n", 1)
                        if line.startswith(b"PING "):
                            sock.sendall(b"PONG My.Little.Services " + line[5:] + b"\r\n")
                        elif b" PONG " in line or line.startswith(b"PONG "):
                            pongs = getattr(self, "_pongs", None)
                            if pongs is not None:
                                pongs.put(line.decode(errors="replace"))
            except OSError:
                return

        threading.Thread(target=pump, daemon=True).start()
        time.sleep(0.2)

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
        """Create an account the way a services server would: over the RFC 2813
        link with ACCOUNTSYNC, carrying SCRAM-SHA-256 verifiers. This works for
        passwords of any length (a REGISTER line is limited to 512 bytes)."""
        if getattr(self, "_services_sock", None) is None:
            self._link_services()
        salt = os.urandom(16)
        iterations = 4096
        salted = hashlib.pbkdf2_hmac("sha256", (password or "").encode(), salt, iterations)
        client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
        server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
        stored_key = hashlib.sha256(client_key).digest()
        b64 = lambda b: base64.b64encode(b).decode()
        line = ":My.Little.Services ACCOUNTSYNC %s %s %d %s %s %d :\r\n" % (
            username, b64(salt), iterations, b64(stored_key), b64(server_key),
            time.time_ns() // 1000,
        )
        token = "sync%d" % time.monotonic_ns()
        self._pongs = queue.Queue()
        self._services_sock.sendall(line.encode() + ("PING %s\r\n" % token).encode())
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if token in self._pongs.get(timeout=1):
                    return
            except queue.Empty:
                pass
        raise AssertionError("account provisioning timed out")


def get_irctest_controller_class() -> Type[IrcdController]:
    return IrcdController
