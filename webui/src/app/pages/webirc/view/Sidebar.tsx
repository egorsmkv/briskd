// Left sidebar: the network, the conversation list, joining a channel, and
// who you are (nickname and connection state).
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { config } from "../../../config.ts";
import { Icon } from "../../../components/Icon.tsx";

export function Sidebar() {
  const network = config().network;
  return (
    <>
      <aside class="sidebar-left" id="sidebar-left">
        <div class="workspace-brand">
          <span class="brand-mark" aria-hidden="true">
            {network.slice(0, 1).toUpperCase()}
          </span>
          <span class="brand-name" title={network}>{network}</span>
          <button
            type="button"
            class="ghost icon mobile-only"
            id="btn-close-left"
            aria-label="Close channels"
          >
            <Icon name="x" size={18} />
          </button>
        </div>
        <nav class="buffer-scroll" aria-label="Conversations">
          <div class="section-label-row">
            <span class="section-label" data-i18n="sec.channels">Channels</span>
            <button
              type="button"
              class="ghost icon btn-discover"
              id="btn-discover"
              title="Browse public channels"
              aria-label="Browse public channels"
            >
              <Icon name="compass" size={15} />
            </button>
          </div>
          <div id="channel-list" role="list"></div>
          <div class="section-label-row">
            <span class="section-label" data-i18n="sec.dms">
              Direct Messages
            </span>
          </div>
          <div id="dm-list" role="list"></div>
        </nav>
        <form class="join-box" id="join-form">
          <Icon name="plus" size={15} class="icon join-icon" />
          <input
            type="text"
            id="inp-join"
            dir="ltr"
            placeholder="Join #channel"
            aria-label="Join a channel"
            data-i18n-placeholder="ph.join"
          />
          <button type="submit" class="small" data-i18n="btn.join">Join</button>
        </form>
        <div class="me-card">
          <span class="me-avatar" id="me-avatar" aria-hidden="true"></span>
          <div class="me-text">
            <span class="me-nick" id="me-nick"></span>
            <span class="me-state">
              <span class="me-online" data-i18n="conn.online">Connected</span>
              <span class="me-offline" data-i18n="conn.offline">
                Offline
              </span>
            </span>
          </div>
        </div>
      </aside>
    </>
  );
}
