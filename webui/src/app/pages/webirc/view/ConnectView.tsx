// The login form: nickname, optional SASL account, channels, server address, ALTCHA.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { config } from "../../../config.ts";

export function ConnectView() {
  return (
    <>
      <section id="connect-view">
        <div class="connect-card">
          <div class="connect-top">
            <h1>{config().network} WebIRC</h1>
            <div class="head-actions">
              <button
                type="button"
                class="small"
                id="btn-settings-1"
                data-i18n="btn.settings"
              >
                Settings
              </button>
            </div>
          </div>
          <p class="sub" data-i18n="connect.sub">
            Team IRC workspace over IRCv3 WebSocket.
          </p>
          <div id="connect-err"></div>
          <form id="connect-form">
            <div class="field">
              <label for="inp-nick" data-i18n="connect.nick">Nickname</label>
              <input
                type="text"
                id="inp-nick"
                required
                maxlength={30}
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
                value={config().defaultChannels}
                placeholder="#lobby"
              />
            </div>
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
            <a href="/signup" data-i18n="foot.signup">Create account</a>{" "}
            &middot;{" "}
            <a href="/verify" data-i18n="foot.verify">Verify account</a>{" "}
            &middot;{" "}
            <a href="/recover" data-i18n="foot.recover">Recover password</a>
          </p>
        </div>
      </section>
    </>
  );
}
