"""irctest controller for this Erlang ircd.

The server runs outside irctest (for example the development container).
Point irctest at it with:

    PYTHONPATH=/path/to/irc-server/test/irctest \
    IRCTEST_SERVER_HOSTNAME=localhost IRCTEST_SERVER_PORT=6667 \
    pytest --controller ircd_controller

There is no services daemon: accounts are created with the server's own
draft/account-registration REGISTER command, so the account and SASL tests
can run. The server needs a short enough `account_password_min` for the
fixed irctest passwords (the dev config sets 4).
"""

import os
import socket
import time
from typing import Optional, Type

from irctest.controllers.external_server import ExternalServerController


class IrcdController(ExternalServerController):
    software_name = "ircd (Erlang/OTP)"
    supported_sasl_mechanisms = {"PLAIN", "EXTERNAL", "SCRAM-SHA-256"}
    supports_sts = False

    def wait_for_services(self) -> None:
        pass

    def registerUser(self, case, username: str, password: Optional[str] = None) -> None:  # type: ignore
        hostname = os.environ["IRCTEST_SERVER_HOSTNAME"]
        port = int(os.environ["IRCTEST_SERVER_PORT"])
        nick = "reg%d" % (time.monotonic_ns() % 100000)
        with socket.create_connection((hostname, port), timeout=10) as sock:
            sock.sendall(
                (
                    "CAP LS 302\r\nCAP REQ draft/account-registration\r\n"
                    "NICK %s\r\nREGISTER %s * %s\r\nQUIT\r\n" % (nick, username, password or "")
                ).encode()
            )
            data = b""
            while b"REGISTER SUCCESS" not in data and b"ACCOUNT_EXISTS" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise AssertionError("account registration failed: %r" % data)
                data += chunk


def get_irctest_controller_class() -> Type[IrcdController]:
    return IrcdController
