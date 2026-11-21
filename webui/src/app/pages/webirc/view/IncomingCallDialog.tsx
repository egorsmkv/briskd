// Incoming call: decline, accept, or (a video call) accept with video.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.

import { Icon } from "../../../components/Icon.tsx";

export function IncomingCallDialog() {
  return (
    <>
      <div
        class="modal-backdrop call-incoming"
        id="call-incoming"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="call-incoming-name"
        aria-describedby="call-incoming-label"
      >
        <div class="modal-card call-card">
          <div class="call-avatar" id="call-incoming-avatar" aria-hidden="true">
          </div>
          <div class="call-incoming-name" id="call-incoming-name" dir="auto">
          </div>
          <div
            class="call-incoming-label"
            id="call-incoming-label"
          >
            Incoming voice call
          </div>
          <div class="call-actions">
            <button
              type="button"
              class="call-round decline"
              id="btn-call-decline"
              aria-label="Decline"
              title="Decline"
            >
              <svg
                viewBox="0 0 24 24"
                width="24"
                height="24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
                class="icon-hangup"
              >
                <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z" />
              </svg>
              <span data-i18n="call.decline">Decline</span>
            </button>
            <button
              type="button"
              class="call-round accept"
              id="btn-call-accept"
              aria-label="Accept"
              title="Accept"
            >
              <svg
                viewBox="0 0 24 24"
                width="24"
                height="24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92z" />
              </svg>
              <span data-i18n="call.accept">Accept</span>
            </button>
            <button
              type="button"
              class="call-round accept hidden"
              id="btn-call-accept-video"
              aria-label="Accept with video"
              title="Accept with video"
            >
              <Icon name="video" size={24} />
              <span data-i18n="call.accept_video">Video</span>
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
