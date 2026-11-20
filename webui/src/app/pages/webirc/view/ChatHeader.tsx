// Conversation header: title, topic, and the per-conversation actions (moderate, E2EE, call, members, settings, connection).
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.

export function ChatHeader() {
  return (
    <>
      <header class="chat-head">
        <div class="head-left">
          <button
            type="button"
            class="small mobile-only"
            id="btn-menu"
            aria-label="Toggle channels"
          >
            ☰
          </button>
          <span class="status-dot" id="status-dot"></span>
          <span class="head-title" id="active-title" data-i18n="status.title">
            Server Status
          </span>
          <span class="head-topic" id="active-topic"></span>
          <button
            type="button"
            class="small hidden"
            id="btn-topic"
            data-i18n="btn.topic"
          >
            Edit topic
          </button>
          <button
            type="button"
            class="small icon-mobile hidden"
            id="btn-mod"
            aria-label="Moderate channel"
            title="Moderate channel"
          >
            <svg
              class="btn-icon"
              viewBox="0 0 24 24"
              width="16"
              height="16"
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
            class="small btn-e2ee hidden"
            id="btn-e2ee"
            title="Toggle end-to-end encryption for this conversation"
          >
            E2EE Off
          </button>
          <button
            type="button"
            class="small icon-mobile btn-call hidden"
            id="btn-call"
            aria-label="Voice call"
            title="Voice call"
          >
            <svg
              class="btn-icon"
              viewBox="0 0 24 24"
              width="16"
              height="16"
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
        <div class="head-right">
          <span class="my-nick" id="my-nick"></span>
          <button
            type="button"
            class="small icon-mobile"
            id="btn-members"
            aria-label="Toggle members"
            title="Members"
          >
            <svg
              class="btn-icon"
              viewBox="0 0 24 24"
              width="16"
              height="16"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
              <circle cx="9" cy="7" r="4" />
              <path d="M22 21v-2a4 4 0 0 0-3-3.87" />
              <path d="M16 3.13a4 4 0 0 1 0 7.75" />
            </svg>
            <span class="btn-label" data-i18n="btn.users">Users</span>
          </button>
          <button
            type="button"
            class="small icon-mobile"
            id="btn-settings-2"
            aria-label="Settings"
            title="Settings"
          >
            <svg
              class="btn-icon"
              viewBox="0 0 24 24"
              width="16"
              height="16"
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
            <span class="btn-label" data-i18n="btn.settings">Settings</span>
          </button>
          <button
            type="button"
            class="small danger icon-mobile"
            id="btn-conn"
            aria-label="Disconnect"
            title="Disconnect"
          >
            <svg
              class="btn-icon"
              id="icon-disconnect"
              viewBox="0 0 24 24"
              width="16"
              height="16"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
              <polyline points="16 17 21 12 16 7" />
              <line x1="21" y1="12" x2="9" y2="12" />
            </svg>
            <svg
              class="btn-icon hidden"
              id="icon-reconnect"
              viewBox="0 0 24 24"
              width="16"
              height="16"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <polyline points="23 4 23 10 17 10" />
              <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
            </svg>
            <span
              class="btn-label"
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
