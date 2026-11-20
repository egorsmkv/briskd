// Above and around the message box: reconnect bar, typing indicator, reply/edit banner, mention list, and the input bar.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts. The input bar is one
// rounded box (attach, voice, text, send) with a keyboard hint below it.
import { Icon } from "../../../components/Icon.tsx";

export function Composer() {
  return (
    <>
      <div class="composer-wrap">
        <div
          class="reconnect-bar hidden"
          id="reconnect-bar"
          role="status"
          aria-live="polite"
        >
          <svg
            class="reconnect-icon"
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
          <span class="reconnect-text" id="reconnect-text"></span>
          <button
            type="button"
            class="small"
            id="btn-reconnect-now"
            data-i18n="rc.now"
          >
            Reconnect now
          </button>
          <button
            type="button"
            class="small"
            id="btn-reconnect-cancel"
            data-i18n="rc.cancel"
          >
            Cancel
          </button>
        </div>
        <div class="typing-bar hidden" id="typing-bar" aria-live="polite">
          <span class="typing-dots" aria-hidden="true">
            <span></span>
            <span></span>
            <span></span>
          </span>
          <span class="typing-text" id="typing-text"></span>
        </div>
        <div class="compose-banner hidden" id="compose-banner">
          <div class="compose-banner-info">
            <span class="compose-banner-label" id="compose-banner-label"></span>
            <span
              class="compose-banner-snippet"
              id="compose-banner-snippet"
              dir="auto"
            >
            </span>
          </div>
          <button
            type="button"
            class="ghost icon small"
            id="btn-compose-cancel"
            aria-label="Cancel"
          >
            <Icon name="x" size={15} />
          </button>
        </div>
        <div
          class="mention-picker hidden"
          id="mention-picker"
          role="listbox"
          aria-label="Mention a user"
        >
        </div>
        <form class="input-bar" id="send-form">
          <button
            type="button"
            class="ghost icon btn-plus hidden"
            id="btn-attach-menu"
            aria-label="Attach"
            title="Attach file, code, or voice message"
          >
            <Icon name="plus" size={18} />
          </button>
          <input type="file" id="inp-file" multiple class="hidden" />
          <button
            type="button"
            class="small btn-voice hidden"
            id="btn-voice"
            aria-label="Stop and send voice message"
            title="Stop & send voice message"
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
              <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
              <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
              <line x1="12" y1="19" x2="12" y2="23" />
              <line x1="8" y1="23" x2="16" y2="23" />
            </svg>
            <span class="voice-timer" id="voice-timer"></span>
          </button>
          <button
            type="button"
            class="small danger hidden"
            id="btn-voice-cancel"
            aria-label="Cancel recording"
            data-i18n="voice.cancel"
          >
            Cancel
          </button>
          <textarea
            id="inp-msg"
            rows={1}
            dir="auto"
            autocomplete="off"
            enterkeyhint="send"
            aria-label="Message"
            placeholder="Type a command, such as /join #channel or /help"
            data-i18n-placeholder="ph.msg"
            aria-describedby="composer-hint"
          >
          </textarea>
          <button
            type="submit"
            class="primary btn-send"
            id="btn-send"
            aria-label="Send"
          >
            <svg
              class="send-icon"
              viewBox="0 0 24 24"
              width="17"
              height="17"
              fill="none"
              stroke="currentColor"
              stroke-width="2.2"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <line x1="22" y1="2" x2="11" y2="13" />
              <polygon points="22 2 15 22 11 13 2 9 22 2" />
            </svg>
            <span class="send-label" data-i18n="btn.send">Send</span>
          </button>
        </form>
        <div class="composer-hint" id="composer-hint" data-i18n="composer.hint">
          Enter to send · Shift+Enter for a new line · Tab completes names ·
          /help for commands
        </div>
      </div>
    </>
  );
}
