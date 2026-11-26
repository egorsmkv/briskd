"""Voice calls end to end: two WebRTC clients (aiortc) call each other over
IRC `CALL` signalling; briskd passes the session descriptions through a real
rtpflux, and audio must arrive in both directions through the relay."""

import asyncio
import base64
import fractions
import math
import os
import re
import secrets
import socket

from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import AudioStreamTrack, VideoStreamTrack
from av import AudioFrame

HOST, PORT = os.environ.get("CALLS_IRC", "127.0.0.1:6667").split(":")
NG_HOST, NG_PORT = os.environ.get("CALLS_NG", "127.0.0.1:2223").split(":")
CAP = "egorsmkv.github.io/calls"
CHUNK = 400


class Tone(AudioStreamTrack):
    """A 48 kHz mono sine tone in 20 ms frames."""

    def __init__(self, freq):
        super().__init__()
        self.freq = freq
        self.pts = 0

    async def recv(self):
        samples = 960
        if self.pts:
            await asyncio.sleep(0.02)
        frame = AudioFrame(format="s16", layout="mono", samples=samples)
        data = bytearray()
        for i in range(samples):
            v = int(8000 * math.sin(2 * math.pi * self.freq * (self.pts + i) / 48000))
            data += v.to_bytes(2, "little", signed=True)
        frame.planes[0].update(bytes(data))
        frame.sample_rate = 48000
        frame.pts = self.pts
        frame.time_base = fractions.Fraction(1, 48000)
        self.pts += samples
        return frame


class Irc:
    def __init__(self, reader, writer, nick):
        self.reader, self.writer, self.nick = reader, writer, nick

    @classmethod
    async def connect(cls, nick):
        reader, writer = await asyncio.open_connection(HOST, int(PORT))
        irc = cls(reader, writer, nick)
        irc.send(f"CAP REQ :{CAP}")
        irc.send(f"NICK {nick}")
        irc.send(f"USER {nick} 0 * :{nick}")
        irc.send("CAP END")
        await irc.expect(lambda l: f" 001 {nick} " in l)
        return irc

    def send(self, line):
        self.writer.write((line + "\r\n").encode())

    async def line(self, timeout=10):
        raw = await asyncio.wait_for(self.reader.readline(), timeout)
        if not raw:
            raise ConnectionError("closed")
        return raw.decode().rstrip("\r\n")

    async def expect(self, pred, timeout=10):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            line = await self.line(max(0.1, deadline - loop.time()))
            if line.startswith("PING"):
                self.send("PONG" + line[4:])
            elif pred(line):
                return line

    async def receive_sdp(self, kind, token):
        """Collect `CALL <kind>` chunks for `token`; return (sender, sdp)."""
        parts, sender = [], None
        pattern = re.compile(rf"^:(\S+?)!\S+ CALL {kind} \S+ {token} (\d+) (\d+) :(\S+)$")
        while True:
            m = pattern.match(await self.expect(lambda l: f" CALL {kind} " in l and token in l))
            sender, part, total, chunk = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
            assert part == len(parts) + 1
            parts.append(chunk)
            if part == total:
                return sender, base64.b64decode("".join(parts)).decode()

    def send_sdp(self, kind, nick, token, sdp):
        b64 = base64.b64encode(sdp.encode()).decode()
        chunks = [b64[i : i + CHUNK] for i in range(0, len(b64), CHUNK)]
        for i, chunk in enumerate(chunks, 1):
            self.send(f"CALL {kind} {nick} {token} {i} {len(chunks)} :{chunk}")


def counting_peer(freq, video=False):
    """A peer connection sending a tone (and, with `video`, generated video
    frames), counting non-silent audio frames and video frames received."""
    pc = RTCPeerConnection()
    pc.addTrack(Tone(freq))
    if video:
        pc.addTrack(VideoStreamTrack())
    received = {"frames": 0, "loud": 0, "video": 0, "width": 0}

    @pc.on("track")
    def on_track(track):
        async def consume():
            while True:
                try:
                    frame = await track.recv()
                except Exception:
                    return
                if track.kind == "video":
                    received["video"] += 1
                    received["width"] = frame.width
                    continue
                received["frames"] += 1
                if any(bytes(frame.planes[0])):
                    received["loud"] += 1

        asyncio.ensure_future(consume())

    return pc, received


def rtpflux_calls():
    """Raw NG `list` reply: the call-ids rtpflux currently holds."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    try:
        cookie = secrets.token_hex(4).encode()
        s.sendto(cookie + b" d7:command4:liste", (NG_HOST, int(NG_PORT)))
        data, _ = s.recvfrom(65535)
    finally:
        s.close()
    assert data.startswith(cookie + b" "), data
    assert b"6:result2:ok" in data, data
    return data


async def until_released(timeout=5):
    """Poll rtpflux until it holds no call from this server."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        listing = rtpflux_calls()
        if b"irc.calltest-" not in listing:
            return
        if loop.time() > deadline:
            raise AssertionError(f"rtpflux still holds a call: {listing!r}")
        await asyncio.sleep(0.2)


def own_ip():
    return socket.gethostbyname(socket.gethostname())


def test_call_through_rtpflux():
    asyncio.run(call_through_rtpflux())


async def call_through_rtpflux():
    alice = await Irc.connect("alice")
    bob = await Irc.connect("bob")
    token = secrets.token_hex(8)

    pc_a, got_a = counting_peer(440)
    pc_b, got_b = counting_peer(660)
    try:
        # Alice offers; aiortc gathers all candidates in setLocalDescription.
        await pc_a.setLocalDescription(await pc_a.createOffer())
        alice.send_sdp("OFFER", "bob", token, pc_a.localDescription.sdp)

        sender, offer = await bob.receive_sdp("OFFER", token)
        assert sender == "alice"
        # rtpflux replaced the media address: Bob never sees Alice's.
        assert own_ip() not in offer
        assert "a=candidate" in offer
        bob.send(f"CALL RINGING alice {token}")
        await alice.expect(lambda l: f"CALL RINGING alice {token}" in l)

        await pc_b.setRemoteDescription(RTCSessionDescription(offer, "offer"))
        await pc_b.setLocalDescription(await pc_b.createAnswer())
        bob.send_sdp("ANSWER", "alice", token, pc_b.localDescription.sdp)

        sender, answer = await alice.receive_sdp("ANSWER", token)
        assert sender == "bob"
        assert own_ip() not in answer
        await pc_a.setRemoteDescription(RTCSessionDescription(answer, "answer"))

        # Two seconds of audio must arrive on each side through rtpflux.
        loop = asyncio.get_running_loop()
        deadline = loop.time() + 20
        while loop.time() < deadline and min(got_a["loud"], got_b["loud"]) < 100:
            await asyncio.sleep(0.2)
        print("received frames", got_a, got_b)
        assert pc_a.connectionState == "connected"
        assert pc_b.connectionState == "connected"
        assert got_a["loud"] >= 100, got_a
        assert got_b["loud"] >= 100, got_b

        # While the call is up rtpflux holds it...
        assert b"irc.calltest-" in rtpflux_calls()

        alice.send(f"CALL HANGUP bob {token} :normal")
        await bob.expect(lambda l: f"CALL HANGUP bob {token} :normal" in l)
        # ...and after the hangup the server's NG delete has released it.
        await until_released()
    finally:
        await pc_a.close()
        await pc_b.close()


def test_video_call_through_rtpflux():
    asyncio.run(video_call_through_rtpflux())


async def video_call_through_rtpflux():
    """Audio and video in one call: the description keeps both sections
    through rtpflux, and both media arrive on each side."""
    alice = await Irc.connect("valice")
    bob = await Irc.connect("vbob")
    # The capability advertises video calls.
    token = secrets.token_hex(8)
    pc_a, got_a = counting_peer(440, video=True)
    pc_b, got_b = counting_peer(660, video=True)
    try:
        await pc_a.setLocalDescription(await pc_a.createOffer())
        offer_sdp = pc_a.localDescription.sdp
        assert "m=video" in offer_sdp
        alice.send_sdp("OFFER", "vbob", token, offer_sdp)

        sender, offer = await bob.receive_sdp("OFFER", token)
        assert sender == "valice"
        assert "m=audio" in offer and "m=video" in offer, offer
        assert own_ip() not in offer
        bob.send(f"CALL RINGING valice {token}")

        await pc_b.setRemoteDescription(RTCSessionDescription(offer, "offer"))
        await pc_b.setLocalDescription(await pc_b.createAnswer())
        bob.send_sdp("ANSWER", "valice", token, pc_b.localDescription.sdp)

        sender, answer = await alice.receive_sdp("ANSWER", token)
        assert "m=video" in answer, answer
        assert own_ip() not in answer
        await pc_a.setRemoteDescription(RTCSessionDescription(answer, "answer"))

        loop = asyncio.get_running_loop()
        deadline = loop.time() + 30
        while loop.time() < deadline and (
            min(got_a["loud"], got_b["loud"]) < 100 or min(got_a["video"], got_b["video"]) < 30
        ):
            await asyncio.sleep(0.2)
        print("received", got_a, got_b)
        assert pc_a.connectionState == "connected"
        assert pc_b.connectionState == "connected"
        assert got_a["loud"] >= 100 and got_b["loud"] >= 100, (got_a, got_b)
        assert got_a["video"] >= 30 and got_b["video"] >= 30, (got_a, got_b)
        assert got_a["width"] > 0 and got_b["width"] > 0

        alice.send(f"CALL HANGUP vbob {token} :normal")
        await bob.expect(lambda l: f"CALL HANGUP vbob {token} :normal" in l)
        await until_released()
    finally:
        await pc_a.close()
        await pc_b.close()
