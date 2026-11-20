// The login form: nickname and channels up front; the SASL account and the
// server address under "Advanced"; ALTCHA; links to the account pages.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { config } from "../../../config.ts";
import { Icon } from "../../../components/Icon.tsx";

export function ConnectView() {
  const network = config().network;
  return (
    <>
      <section id="connect-view">
        <div class="connect-card">
          <div class="connect-top">
            <span class="brand-mark brand-mark-lg" aria-hidden="true">
              {network.slice(0, 1).toUpperCase()}
            </span>
            <button
              type="button"
              class="ghost icon"
              id="btn-settings-1"
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
          </div>
          <h1>{network}</h1>
          <p class="sub" data-i18n="connect.sub">
            Team IRC workspace over IRCv3 WebSocket.
          </p>
          <div id="connect-err" role="alert"></div>
          <form id="connect-form">
            <div class="field">
              <label for="inp-nick" data-i18n="connect.nick">Nickname</label>
              <input
                type="text"
                id="inp-nick"
                required
                maxlength={30}
                autocomplete="nickname"
                autocapitalize="off"
                spellcheck={false}
                placeholder="alex"
                data-i18n-placeholder="connect.nick.ph"
              />
            </div>
            <div class="field">
              <label for="inp-channels" data-i18n="connect.channels">
                Channels
              </label>
              <input
                type="text"
                id="inp-channels"
                dir="ltr"
                autocapitalize="off"
                spellcheck={false}
                value={config().defaultChannels}
                placeholder="#lobby"
              />
            </div>
            <details class="connect-advanced" id="connect-advanced">
              <summary>
                <Icon name="chevronDown" size={15} class="icon chev" />
                <span data-i18n="connect.advanced">
                  Account and server
                </span>
              </summary>
              <div class="row-2">
                <div class="field">
                  <label for="inp-acct" data-i18n="connect.acct">
                    SASL Account (optional)
                  </label>
                  <input
                    type="text"
                    id="inp-acct"
                    dir="ltr"
                    autocomplete="username"
                    maxlength={64}
                  />
                </div>
                <div class="field">
                  <label for="inp-pass" data-i18n="connect.pass">
                    SASL Password
                  </label>
                  <input
                    type="password"
                    id="inp-pass"
                    dir="ltr"
                    autocomplete="current-password"
                    maxlength={256}
                  />
                </div>
              </div>
              <div class="field">
                <label for="inp-ws" data-i18n="connect.ws">WebSocket URL</label>
                <input type="text" id="inp-ws" dir="ltr" required />
              </div>
            </details>
            <div class="field">
              <div class="altcha-box">
                <label class="altcha-left" for="altcha-check">
                  <input type="checkbox" id="altcha-check" />
                  <span id="altcha-label">I'm not a robot</span>
                </label>
                <a
                  class="altcha-brand"
                  href="https://altcha.org/"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  ALTCHA
                </a>
              </div>
            </div>
            <button
              type="submit"
              class="primary btn-full"
              id="btn-connect"
              data-i18n="connect.btn"
            >
              Connect
            </button>
          </form>
          <p class="foot-links">
            <a href="/signup" data-i18n="foot.signup">Create account</a>
            <span aria-hidden="true">·</span>
            <a href="/verify" data-i18n="foot.verify">Verify account</a>
            <span aria-hidden="true">·</span>
            <a href="/recover" data-i18n="foot.recover">Recover password</a>
          </p>
        </div>
      </section>
    </>
  );
}
