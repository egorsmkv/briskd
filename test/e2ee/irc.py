"""Minimal IRCv3 client for the E2EE end-to-end tests: line framing, message
tags (with value escaping), and a blocking reader with timeouts."""

import socket
import time
from dataclasses import dataclass, field

ESCAPES = {"\\:": ";", "\\s": " ", "\\\\": "\\", "\\r": "\r", "\\n": "\n"}


def unescape(value):
    out, i = [], 0
    while i < len(value):
        pair = value[i : i + 2]
        if pair in ESCAPES:
            out.append(ESCAPES[pair])
            i += 2
        elif value[i] == "\\":
            i += 1
        else:
            out.append(value[i])
            i += 1
    return "".join(out)


def escape(value):
    return (
        value.replace("\\", "\\\\").replace(";", "\\:").replace(" ", "\\s").replace("\r", "\\r").replace("\n", "\\n")
    )


@dataclass
class Message:
    tags: dict = field(default_factory=dict)
    prefix: str = ""
    command: str = ""
    params: list = field(default_factory=list)
    raw: str = ""

    @property
    def nick(self):
        return self.prefix.split("!", 1)[0]


def parse(line):
    msg = Message(raw=line)
    if line.startswith("@"):
        tags, line = line[1:].split(" ", 1)
        for item in tags.split(";"):
            key, _, value = item.partition("=")
            msg.tags[key] = unescape(value) if value else None
    if line.startswith(":"):
        msg.prefix, line = line[1:].split(" ", 1)
    if " :" in line:
        line, trailing = line.split(" :", 1)
        params = line.split()
        params.append(trailing)
    else:
        params = line.split()
    msg.command, msg.params = params[0].upper(), params[1:]
    return msg


def tag_section(tags):
    if not tags:
        return ""
    return "@" + ";".join(k if v is None else f"{k}={escape(str(v))}" for k, v in tags.items()) + " "


class Connection:
    def __init__(self, host, port, timeout=10.0):
        deadline = time.monotonic() + 60
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=5)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.5)
        self.timeout = timeout
        self.buffer = b""
        self.log = []

    def send(self, line, tags=None):
        data = (tag_section(tags) + line).encode()
        self.sock.sendall(data + b"\r\n")

    def read(self, timeout=None):
        """The next message, or None after `timeout` seconds."""
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while b"\r\n" not in self.buffer:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("server closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\r\n", 1)
        msg = parse(line.decode("utf-8", "replace"))
        if msg.command == "PING":
            self.send("PONG :" + (msg.params[-1] if msg.params else ""))
        self.log.append(msg)
        return msg

    def close(self):
        try:
            self.send("QUIT :bye")
        except OSError:
            pass
        self.sock.close()
