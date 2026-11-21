/// <reference lib="deno.ns" />
import { defaultWsUrl } from "./ws_url.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`expected ${expected}, got ${actual}`);
  }
}

const https = {
  protocol: "https:",
  hostname: "ml-lab.example.ts.net",
  host: "ml-lab.example.ts.net",
};
const http = {
  protocol: "http:",
  hostname: "localhost",
  host: "localhost:8081",
};

Deno.test("HTTPS pages use wss: the TLS port, else /ws on the page's origin", () => {
  assertEquals(
    defaultWsUrl(https, "8080", "8443"),
    "wss://ml-lab.example.ts.net:8443/",
  );
  // Behind a TLS proxy only the plain port exists: never ws:// (mixed content).
  assertEquals(
    defaultWsUrl(https, "8080", ""),
    "wss://ml-lab.example.ts.net/ws",
  );
  assertEquals(
    defaultWsUrl({ ...https, host: "irc.example.org:4443" }, "", ""),
    "wss://irc.example.org:4443/ws",
  );
});

Deno.test("HTTP pages use the plain port, then the TLS one, then the origin", () => {
  assertEquals(defaultWsUrl(http, "8080", "8443"), "ws://localhost:8080/");
  assertEquals(defaultWsUrl(http, "", "8443"), "wss://localhost:8443/");
  assertEquals(defaultWsUrl(http, "", ""), "ws://localhost:8081/");
});
