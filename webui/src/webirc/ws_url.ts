// The WebSocket URL the connect form starts with (session.ts), from where
// the page was loaded and the server's WebSocket ports. Pure, so it is
// unit-tested in ws_url_test.ts.

/**
 * - HTTPS page and a TLS WebSocket port: `wss://<host>:<wss_port>/`.
 * - HTTPS page without one: `wss://<page origin>/ws`. A TLS reverse proxy
 *   in front of the server (Tailscale Serve, nginx, Caddy) serves the page and
 *   forwards `/ws` to the plain WebSocket port; a `ws://` URL would be
 *   blocked as mixed content on an HTTPS page anyway.
 * - HTTP page: `ws://<host>:<ws_port>/`, else the TLS port, else the page's
 *   own origin.
 */
export function defaultWsUrl(
  loc: { protocol: string; hostname: string; host: string },
  wsPort: string,
  wssPort: string,
): string {
  const host = loc.hostname || "127.0.0.1";
  if (loc.protocol === "https:") {
    return wssPort ? `wss://${host}:${wssPort}/` : `wss://${loc.host}/ws`;
  }
  if (wsPort) return `ws://${host}:${wsPort}/`;
  if (wssPort) return `wss://${host}:${wssPort}/`;
  return `ws://${loc.host}/`;
}
