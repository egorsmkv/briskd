// The message list, the call bar, the video call stage, the remote call
// audio, and the jump-to-latest button.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.

import { Icon } from "../../../components/Icon.tsx";

export function MessageArea() {
  return (
    <>
      <div class="messages" id="messages"></div>
      <div
        class="call-stage hidden"
        id="call-stage"
        role="region"
        aria-label="Video call"
      >
        <video
          class="call-remote-video"
          id="call-remote-video"
          autoplay
          playsInline
        >
        </video>
        <div class="call-stage-placeholder" id="call-stage-placeholder">
          <div class="call-avatar" id="call-stage-avatar" aria-hidden="true">
          </div>
          <div class="call-stage-name" id="call-stage-name" dir="auto"></div>
          <div class="call-stage-note" id="call-stage-note"></div>
        </div>
        <video
          class="call-local-video hidden"
          id="call-local-video"
          autoplay
          playsInline
          muted
          aria-label="Your camera"
        >
        </video>
        <div class="call-stage-tools">
          <button
            type="button"
            class="call-btn ghost-dark"
            id="btn-call-stage-mini"
            aria-label="Minimize video"
            title="Minimize video"
          >
            <Icon name="minimize" size={18} class="icon icon-stage-mini" />
            <Icon
              name="maximize"
              size={18}
              class="icon icon-stage-restore hidden"
            />
          </button>
          <button
            type="button"
            class="call-btn ghost-dark"
            id="btn-call-stage-full"
            aria-label="Full screen"
            title="Full screen"
          >
            <Icon name="maximize" size={18} />
          </button>
        </div>
      </div>
      <div
        class="call-dock hidden"
        id="call-dock"
        role="region"
        aria-label="Voice call"
      >
        <div class="call-dock-avatar" id="call-dock-avatar" aria-hidden="true">
        </div>
        <div class="call-dock-info">
          <button
            type="button"
            class="call-dock-peer"
            id="call-dock-peer"
            dir="ltr"
          >
          </button>
          <span
            class="call-dock-status"
            id="call-dock-status"
            aria-live="polite"
          >
          </span>
        </div>
        <button
          type="button"
          class="call-btn"
          id="btn-call-mute"
          aria-pressed="false"
          aria-label="Mute"
          title="Mute"
        >
          <svg
            class="icon-mic"
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
            <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
            <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
            <line x1="12" y1="19" x2="12" y2="23" />
            <line x1="8" y1="23" x2="16" y2="23" />
          </svg>
          <svg
            class="icon-mic-off hidden"
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
            <line x1="1" y1="1" x2="23" y2="23" />
            <path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6" />
            <path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2a7 7 0 0 1-.11 1.23" />
            <line x1="12" y1="19" x2="12" y2="23" />
            <line x1="8" y1="23" x2="16" y2="23" />
          </svg>
        </button>
        <button
          type="button"
          class="call-btn hidden"
          id="btn-call-camera"
          aria-pressed="true"
          aria-label="Turn camera off"
          title="Turn camera off"
        >
          <Icon name="video" size={18} class="icon icon-cam" />
          <Icon name="video-off" size={18} class="icon icon-cam-off hidden" />
        </button>
        <button
          type="button"
          class="call-btn"
          id="btn-call-hold"
          aria-pressed="false"
          aria-label="Hold"
          title="Hold"
          disabled
        >
          <svg
            class="icon-pause"
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
            <rect x="6" y="4" width="4" height="16" rx="1" />
            <rect x="14" y="4" width="4" height="16" rx="1" />
          </svg>
          <svg
            class="icon-play hidden"
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
            <polygon points="6 4 20 12 6 20 6 4" />
          </svg>
        </button>
        <button
          type="button"
          class="call-btn hangup"
          id="btn-call-hangup"
          aria-label="Hang up"
          title="Hang up"
        >
          <svg
            viewBox="0 0 24 24"
            width="18"
            height="18"
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
        </button>
      </div>
      <audio id="call-audio" autoplay hidden></audio>
      <button
        type="button"
        class="scroll-bottom-fab hidden"
        id="btn-scroll-bottom"
        aria-label="Scroll to latest messages"
        title="Jump to bottom"
      >
        <svg
          viewBox="0 0 24 24"
          width="18"
          height="18"
          fill="none"
          stroke="currentColor"
          stroke-width="2.2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <polyline points="6 9 12 15 18 9" />
        </svg>
        <span class="fab-count hidden" id="scroll-fab-count" aria-hidden="true">
        </span>
      </button>
    </>
  );
}
