// Left sidebar: network name, conversation list, join form.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { config } from "../../../config.ts";

export function Sidebar() {
  return (
    <>
      <aside class="sidebar-left" id="sidebar-left">
        <div class="workspace-brand">
          <span>{config().network}</span>
          <button
            type="button"
            class="small mobile-only"
            id="btn-close-left"
            aria-label="Close channels"
          >
            ×
          </button>
        </div>
        <div class="buffer-scroll">
          <div class="section-label-row">
            <span class="section-label" data-i18n="sec.channels">Channels</span>
            <button
              type="button"
              class="btn-discover"
              id="btn-discover"
              title="Browse public channels"
              data-i18n="btn.discover"
            >
              Discover
            </button>
          </div>
          <div id="channel-list"></div>
          <div class="section-label" data-i18n="sec.dms">Direct Messages</div>
          <div id="dm-list"></div>
        </div>
        <form class="join-box" id="join-form">
          <input
            type="text"
            id="inp-join"
            dir="ltr"
            placeholder="#channel"
            data-i18n-placeholder="ph.join"
          />
          <button type="submit" class="small" data-i18n="btn.join">Join</button>
        </form>
      </aside>
    </>
  );
}
