/// <reference lib="deno.ns" />
import { CallManager, type CallView } from "./calls.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

function setup() {
  const sent: string[] = [];
  const ended: Array<[string, string]> = [];
  const views: CallView[] = [];
  const audio = { srcObject: null } as unknown as HTMLAudioElement;
  const calls = new CallManager({
    send: (l) => sent.push(l),
    onChange: (v) => views.push(v),
    onEnded: (peer, summary) => ended.push([peer, summary]),
    remoteAudio: () => audio,
  });
  calls.enabled = true;
  return { calls, sent, ended, views };
}

/** CALL OFFER lines (as parsed params) carrying `sdp` in chunks of 400. */
function offerParams(token: string, sdp: string): string[][] {
  const b64 = btoa(sdp);
  const chunks: string[] = [];
  for (let i = 0; i < b64.length; i += 400) chunks.push(b64.slice(i, i + 400));
  return chunks.map((c, i) => [
    "OFFER",
    "me",
    token,
    String(i + 1),
    String(chunks.length),
    c,
  ]);
}

const SDP = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" +
  "a=x-padding\r\n".repeat(60);

Deno.test("incoming offer is reassembled, rings, and can be declined", () => {
  const { calls, sent, ended } = setup();
  const lines = offerParams("tok12345", SDP);
  assert(lines.length > 1, "offer spans several chunks");
  for (const p of lines) calls.handle("alice", p);
  assert(calls.state.phase === "incoming", "phase incoming");
  assert(calls.state.peer === "alice", "peer recorded");
  assert(sent.includes("CALL RINGING alice tok12345"), "ringing sent");
  calls.decline();
  assert(sent.includes("CALL REJECT alice tok12345 :declined"), "reject sent");
  assert(calls.state.phase === "idle", "idle after decline");
  assert(ended.length === 1 && ended[0][0] === "alice", "summary for alice");
});

Deno.test("a second caller gets busy while a call rings", () => {
  const { calls, sent, ended } = setup();
  for (const p of offerParams("tok12345", SDP)) calls.handle("alice", p);
  for (const p of offerParams("tok67890", SDP)) calls.handle("bob", p);
  assert(sent.includes("CALL REJECT bob tok67890 :busy"), "busy reject");
  assert(calls.state.peer === "alice", "first call kept");
  assert(ended.some(([p]) => p === "bob"), "missed call noted for bob");
});

Deno.test("hangup before answering is a missed call", () => {
  const { calls, ended } = setup();
  for (const p of offerParams("tok12345", SDP)) calls.handle("alice", p);
  calls.handle("irc.test", ["HANGUP", "me", "tok12345", "no-answer"]);
  assert(calls.state.phase === "idle", "idle");
  assert(ended[0][1] === "Missed call from alice", "missed call text");
});

Deno.test("out-of-order or malformed chunks are ignored", () => {
  const { calls, sent } = setup();
  const lines = offerParams("tok12345", SDP);
  calls.handle("alice", lines[1]);
  calls.handle("alice", lines[0]);
  assert(calls.state.phase === "idle", "incomplete offer ignored");
  calls.handle("alice", ["OFFER", "me", "bad token", "1", "1", "AAAA"]);
  calls.handle("alice", ["OFFER", "me", "tok12345", "1", "99", "AAAA"]);
  calls.handle("alice", ["OFFER", "me", "tok12345", "1", "1", "!!!!"]);
  assert(calls.state.phase === "idle", "invalid offers ignored");
  assert(sent.length === 0, "nothing sent");
});

Deno.test("messages for another token do not affect the call", () => {
  const { calls } = setup();
  for (const p of offerParams("tok12345", SDP)) calls.handle("alice", p);
  calls.handle("alice", ["HANGUP", "me", "othertok1", "normal"]);
  calls.handleFail("TARGET_BUSY", "othertok1", "busy");
  assert(calls.state.phase === "incoming", "still ringing");
});

Deno.test("disabled manager ignores call()", async () => {
  const { calls, sent } = setup();
  calls.enabled = false;
  await calls.call("alice");
  assert(sent.length === 0 && calls.state.phase === "idle", "no call");
});
