// Shown for an unknown path or a page this server does not offer.
import { config } from "../config.ts";

export function NotFound() {
  const webirc = config().features.webirc;
  return (
    <main class="card">
      <h1>Page not found</h1>
      <p class="sub">
        This page does not exist or is not enabled on this server.
      </p>
      {webirc && (
        <p class="foot-links">
          <a href="/">Open WebIRC</a>
        </p>
      )}
    </main>
  );
}
