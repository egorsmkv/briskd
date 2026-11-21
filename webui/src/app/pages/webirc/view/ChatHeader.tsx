// Conversation header: what is open (glyph, title, topic) and its actions
// (topic, moderation, call), then the icon actions on the right: end-to-end
// encryption (an open lock when off, a closed lock when on), message search,
// members, settings, and the connection.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts. `data-kind` on the
// header (status, channel, or dm) picks the glyph; the connection dot sits
// on it.
import { Icon } from "../../../components/Icon.tsx";

export function ChatHeader() {
  return (
    <>
      <header class="chat-head" id="chat-head" data-kind="status">
        <div class="head-left">
          <button
            type="button"
            class="ghost icon mobile-only"
            id="btn-menu"
            aria-label="Toggle channels"
            title="Conversations"
          >
            <Icon name="menu" size={18} />
          </button>
          <span class="head-glyph" aria-hidden="true">
            <Icon name="server" class="icon glyph-status" />
            <Icon name="hash" class="icon glyph-channel" />
            <Icon name="at" class="icon glyph-dm" />
            <span class="status-dot" id="status-dot"></span>
          </span>
          <div class="head-text">
            <span class="head-title" id="active-title" data-i18n="status.title">
              Server Status
            </span>
            <span class="head-topic" id="active-topic"></span>
          </div>
          <div class="head-tools">
            <button
              type="button"
              class="ghost small hidden"
              id="btn-topic"
              title="Edit topic"
            >
              <Icon name="pencil" size={15} />
              <span class="btn-label" data-i18n="btn.topic">Edit topic</span>
            </button>
            <button
              type="button"
              class="ghost small icon-mobile hidden"
              id="btn-mod"
              aria-label="Moderate channel"
              title="Moderate channel"
            >
              <svg
                class="icon"
                viewBox="0 0 24 24"
                width="15"
                height="15"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
              </svg>
              <span class="btn-label" data-i18n="btn.mod">Moderate</span>
            </button>
            <button
              type="button"
              class="ghost small icon-mobile btn-call hidden"
              id="btn-call"
              aria-label="Voice call"
              title="Voice call"
            >
              <svg
                class="icon"
                viewBox="0 0 24 24"
                width="15"
                height="15"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z" />
              </svg>
              <span class="btn-label" data-i18n="call.button">Call</span>
            </button>
          </div>
        </div>
        <div class="head-right">
          <span class="my-nick" id="my-nick" title="Your nickname"></span>
          <button
            type="button"
            class="ghost icon btn-e2ee hidden"
            id="btn-e2ee"
            aria-pressed="false"
            title="Toggle end-to-end encryption for this conversation"
          >
            <Icon name="unlock" size={18} class="icon e2ee-off-icon" />
            <Icon name="lock" size={18} class="icon e2ee-on-icon" />
            <span class="sr-only" id="btn-e2ee-label">Not encrypted</span>
          </button>
          <button
            type="button"
            class="ghost icon hidden"
            id="btn-search"
            aria-label="Search messages"
            aria-keyshortcuts="Control+K Meta+K"
            title="Search messages (Ctrl+K)"
          >
            <Icon name="search" size={18} />
          </button>
          <button
            type="button"
            class="ghost icon"
            id="btn-members"
            aria-label="Toggle members"
            title="Members"
          >
            <Icon name="users" size={18} />
          </button>
          <button
            type="button"
            class="ghost icon"
            id="btn-settings-2"
            aria-label="Settings"
            title="Settings"
          >
            <svg
              class="icon"
              viewBox="0 0 24 24"
              width="18"
              height="18"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <circle cx="12" cy="12" r="3" />
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
            </svg>
          </button>
          <span class="head-sep" aria-hidden="true"></span>
          <button
            type="button"
            class="ghost icon ghost-danger"
            id="btn-conn"
            aria-label="Disconnect"
            title="Disconnect"
          >
            <Icon name="logout" size={18} id="icon-disconnect" />
            <Icon name="refresh" size={18} id="icon-reconnect" hidden />
            <span
              class="sr-only"
              id="btn-conn-label"
              data-i18n="btn.disconnect"
            >
              Disconnect
            </span>
          </button>
        </div>
      </header>
    </>
  );
}
