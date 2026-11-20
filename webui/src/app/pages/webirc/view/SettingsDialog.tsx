// Settings dialog: General, Calls, E2EE, and My Data tabs.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { Icon } from "../../../components/Icon.tsx";

export function SettingsDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="settings-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-title"
      >
        <div class="modal-card modal-wide">
          <div class="modal-head">
            <h2 id="settings-title" data-i18n="settings.title">
              Workspace Settings
            </h2>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-settings"
              aria-label="Close settings"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <div class="modal-tabs" role="tablist">
            <button
              type="button"
              class="modal-tab active"
              id="tab-settings-general"
              role="tab"
              aria-selected="true"
              data-i18n="settings.tab.general"
            >
              General
            </button>
            <button
              type="button"
              class="modal-tab"
              id="tab-settings-calls"
              role="tab"
              aria-selected="false"
              aria-controls="pane-settings-calls"
              data-i18n="settings.tab.calls"
            >
              Calls
            </button>
            <button
              type="button"
              class="modal-tab"
              id="tab-settings-e2ee"
              role="tab"
              aria-selected="false"
              data-i18n="settings.tab.e2ee"
            >
              E2EE Keys
            </button>
            <button
              type="button"
              class="modal-tab"
              id="tab-settings-data"
              role="tab"
              aria-selected="false"
              aria-controls="pane-settings-data"
              data-i18n="settings.tab.data"
            >
              My Data
            </button>
          </div>
          <div class="modal-body">
            <div
              class="modal-pane active"
              id="pane-settings-general"
              role="tabpanel"
            >
              <div class="setting-group">
                <div class="setting-label" data-i18n="settings.theme">
                  Theme
                </div>
                <div class="theme-grid" id="theme-grid"></div>
              </div>
              <div class="setting-row">
                <label for="opt-lang" data-i18n="settings.lang">Language</label>
                <select id="opt-lang">
                  <option value="en">English</option>
                  <option value="he">עברית (Hebrew)</option>
                </select>
              </div>
              <div class="setting-row">
                <label for="opt-layout" data-i18n="settings.layout">
                  Screen layout
                </label>
                <select id="opt-layout">
                  <option value="auto" data-i18n="settings.layout.auto">
                    Auto (responsive)
                  </option>
                  <option value="mobile" data-i18n="settings.layout.mobile">
                    Mobile / iPhone
                  </option>
                  <option value="desktop" data-i18n="settings.layout.desktop">
                    Desktop
                  </option>
                </select>
              </div>
              <div class="setting-row">
                <label for="opt-density" data-i18n="settings.density">
                  Message density
                </label>
                <select id="opt-density">
                  <option
                    value="comfortable"
                    data-i18n="settings.density.comfortable"
                  >
                    Comfortable (avatars)
                  </option>
                  <option value="compact" data-i18n="settings.density.compact">
                    Compact (classic IRC)
                  </option>
                </select>
              </div>
              <div class="setting-row">
                <label for="opt-fontsize" data-i18n="settings.fontsize">
                  Font size
                </label>
                <select id="opt-fontsize">
                  <option value="small" data-i18n="settings.fontsize.small">
                    Small (13px)
                  </option>
                  <option value="normal" data-i18n="settings.fontsize.normal">
                    Normal (14px)
                  </option>
                  <option value="large" data-i18n="settings.fontsize.large">
                    Large (15.5px)
                  </option>
                </select>
              </div>
              <label class="setting-check">
                <input type="checkbox" id="opt-timestamps" checked />
                <span data-i18n="settings.timestamps">
                  Show message timestamps
                </span>
              </label>
              <label class="setting-check">
                <input type="checkbox" id="opt-joinpart" checked />
                <span data-i18n="settings.joinpart">
                  Show join, part, and quit events
                </span>
              </label>
              <label class="setting-check">
                <input type="checkbox" id="opt-notify" />
                <span data-i18n="settings.notify">
                  Desktop notifications on mentions
                </span>
              </label>
              <div class="setting-group">
                <div class="setting-label" data-i18n="settings.features">
                  Chat Features
                </div>
                <label class="setting-check">
                  <input type="checkbox" id="opt-reactions" checked />
                  <span data-i18n="settings.reactions">Emoji reactions</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-replies" checked />
                  <span data-i18n="settings.replies">Message replies</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-typing" checked />
                  <span data-i18n="settings.typing">Typing indicators</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-editing" checked />
                  <span data-i18n="settings.editing">Message editing</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-redaction" checked />
                  <span data-i18n="settings.redaction">
                    Message deletion / redaction
                  </span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-link-previews" checked />
                  <span data-i18n="settings.link_previews">
                    Link previews (OpenGraph cards)
                  </span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-remote-avatars" />
                  <span data-i18n="settings.remote_avatars">
                    Load avatars from other sites
                  </span>
                </label>
              </div>
            </div>

            <div
              class="modal-pane"
              id="pane-settings-calls"
              role="tabpanel"
              aria-labelledby="tab-settings-calls"
            >
              <div
                class="call-settings-note hidden"
                id="call-settings-permission"
              >
                <span data-i18n="callset.permission">
                  Allow microphone access to see your device names.
                </span>
                <button
                  type="button"
                  class="small"
                  id="btn-callset-allow"
                  data-i18n="callset.allow"
                >
                  Allow access
                </button>
              </div>
              <div
                class="call-settings-note hidden"
                id="call-settings-error"
                role="alert"
              >
              </div>
              <div class="setting-group">
                <div class="setting-label" data-i18n="callset.devices">
                  Devices
                </div>
                <div class="setting-row">
                  <label for="opt-call-input" data-i18n="callset.input">
                    Microphone
                  </label>
                  <select id="opt-call-input"></select>
                </div>
                <div class="mic-test">
                  <button
                    type="button"
                    class="small"
                    id="btn-callset-mictest"
                    aria-pressed="false"
                    data-i18n="callset.mictest"
                  >
                    Test microphone
                  </button>
                  <div
                    class="mic-meter"
                    id="call-mic-meter"
                    role="meter"
                    aria-valuemin={0}
                    aria-valuemax={100}
                    aria-valuenow={0}
                    aria-label="Microphone level"
                    data-i18n-aria-label="callset.level"
                  >
                    <div class="mic-meter-fill" id="call-mic-meter-fill"></div>
                  </div>
                </div>
                <div class="setting-row" id="row-call-output">
                  <label for="opt-call-output" data-i18n="callset.output">
                    Speakers
                  </label>
                  <select id="opt-call-output"></select>
                </div>
                <div
                  class="call-settings-hint hidden"
                  id="call-output-unsupported"
                  data-i18n="callset.output_unsupported"
                >
                  This browser plays calls through the system's default output.
                </div>
                <div class="setting-row">
                  <label for="opt-call-volume" data-i18n="callset.volume">
                    Call volume
                  </label>
                  <div class="volume-control">
                    <input
                      type="range"
                      id="opt-call-volume"
                      min={0}
                      max={100}
                      step={5}
                    />
                    <span class="volume-value" id="call-volume-value">
                      100%
                    </span>
                  </div>
                </div>
                <div class="speaker-test">
                  <button
                    type="button"
                    class="small"
                    id="btn-callset-speakertest"
                    data-i18n="callset.speakertest"
                  >
                    Play test sound
                  </button>
                </div>
              </div>
              <div class="setting-group">
                <div class="setting-label" data-i18n="callset.processing">
                  Audio processing
                </div>
                <label class="setting-check">
                  <input type="checkbox" id="opt-call-echo" />
                  <span data-i18n="callset.echo">Echo cancellation</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-call-noise" />
                  <span data-i18n="callset.noise">Noise suppression</span>
                </label>
                <label class="setting-check">
                  <input type="checkbox" id="opt-call-agc" />
                  <span data-i18n="callset.agc">
                    Automatic microphone volume
                  </span>
                </label>
              </div>
              <div class="setting-group">
                <div class="setting-label" data-i18n="callset.quality">
                  Quality
                </div>
                <div class="setting-row">
                  <label for="opt-call-bitrate" data-i18n="callset.bitrate">
                    Audio quality
                  </label>
                  <select id="opt-call-bitrate">
                    <option value="0" data-i18n="callset.bitrate.auto">
                      Automatic
                    </option>
                    <option value="16" data-i18n="callset.bitrate.16">
                      Data saver (16 kbps)
                    </option>
                    <option value="32" data-i18n="callset.bitrate.32">
                      Standard (32 kbps)
                    </option>
                    <option value="64" data-i18n="callset.bitrate.64">
                      High (64 kbps)
                    </option>
                    <option value="128" data-i18n="callset.bitrate.128">
                      Studio (128 kbps)
                    </option>
                  </select>
                </div>
                <label class="setting-check">
                  <input type="checkbox" id="opt-call-ringtone" />
                  <span data-i18n="callset.ringtone">
                    Ring sound for incoming calls
                  </span>
                </label>
                <div class="call-settings-hint" data-i18n="callset.live_hint">
                  Changes apply to a call in progress right away.
                </div>
              </div>
            </div>

            <div class="modal-pane" id="pane-settings-e2ee" role="tabpanel">
              <div class="e2ee-status-banner" id="e2ee-status-banner"></div>
              <div class="e2ee-kv-grid">
                <div class="e2ee-kv">
                  <span class="k" data-i18n="e2ee.account">Account</span>
                  <span class="v" id="e2ee-account">-</span>
                </div>
                <div class="e2ee-kv">
                  <span class="k" data-i18n="e2ee.device">Device ID</span>
                  <span class="v" id="e2ee-device">-</span>
                </div>
                <div class="e2ee-kv">
                  <span class="k" data-i18n="e2ee.prekeys">
                    One-time Prekeys
                  </span>
                  <span class="v" id="e2ee-prekeys">-</span>
                </div>
                <div class="e2ee-kv">
                  <span class="k" data-i18n="e2ee.sessions">
                    Active Sessions
                  </span>
                  <span class="v" id="e2ee-sessions">-</span>
                </div>
              </div>
              <div class="setting-group">
                <div class="setting-label" data-i18n="e2ee.fingerprint">
                  Your Identity Fingerprint
                </div>
                <div class="e2ee-fp" dir="ltr" id="e2ee-fingerprint">-</div>
              </div>
              <div class="e2ee-actions">
                <button
                  type="button"
                  class="small"
                  id="btn-e2ee-export"
                  data-i18n="e2ee.download"
                >
                  Download Keys
                </button>
                <button
                  type="button"
                  class="small"
                  id="btn-e2ee-import"
                  data-i18n="e2ee.upload"
                >
                  Upload Keys
                </button>
                <input
                  type="file"
                  id="inp-e2ee-file"
                  accept=".json,application/json"
                  class="hidden"
                />
                <button
                  type="button"
                  class="small"
                  id="btn-e2ee-replenish"
                  data-i18n="e2ee.replenish"
                >
                  Upload Prekeys
                </button>
                <button
                  type="button"
                  class="small"
                  id="btn-e2ee-rotate"
                  data-i18n="e2ee.rotate"
                >
                  Rotate Channel Key
                </button>
                <button
                  type="button"
                  class="small danger"
                  id="btn-e2ee-reset"
                  data-i18n="e2ee.reset"
                >
                  Reset Device Keys
                </button>
              </div>
              <div class="setting-group">
                <div class="setting-label" data-i18n="e2ee.peers">
                  Trusted Peer Devices (TOFU Safety Numbers)
                </div>
                <div class="e2ee-peers" id="e2ee-peers"></div>
              </div>
            </div>

            <div
              class="modal-pane"
              id="pane-settings-data"
              role="tabpanel"
              aria-labelledby="tab-settings-data"
            >
              <section class="data-card" aria-labelledby="data-browser-title">
                <h3 id="data-browser-title" data-i18n="data.browser.title">
                  Data in this browser
                </h3>
                <p class="data-text" data-i18n="data.browser.text">
                  Your settings, theme, language, saved session, cached direct
                  messages, and end-to-end encryption keys are stored in this
                  browser. Clearing them signs you out here; encrypted messages
                  you cannot decrypt elsewhere stay unreadable.
                </p>
                <div class="data-actions">
                  <button
                    type="button"
                    class="small danger"
                    id="btn-clear-browser"
                    data-i18n="data.browser.clear"
                  >
                    Clear this browser's data
                  </button>
                  <span
                    class="data-confirm hidden"
                    id="clear-browser-confirm"
                    role="group"
                  >
                    <span data-i18n="data.browser.sure">Are you sure?</span>
                    <button
                      type="button"
                      class="small danger"
                      id="btn-clear-browser-yes"
                      data-i18n="data.browser.yes"
                    >
                      Yes, clear it
                    </button>
                    <button
                      type="button"
                      class="small"
                      id="btn-clear-browser-no"
                      data-i18n="data.cancel"
                    >
                      Cancel
                    </button>
                  </span>
                </div>
              </section>

              <section
                class="data-card danger-zone"
                aria-labelledby="data-account-title"
              >
                <h3 id="data-account-title" data-i18n="data.account.title">
                  Delete my account
                </h3>
                <p class="data-text" data-i18n="data.account.text">
                  Deletes your account on this server and signs out every
                  connection using it.
                </p>
                <ul class="data-list">
                  <li data-i18n="data.account.item.account">
                    Your account, password, email address, and client
                    certificates
                  </li>
                  <li data-i18n="data.account.item.messages">
                    The messages you sent while logged in, from channel and
                    direct message history
                  </li>
                  <li data-i18n="data.account.item.private">
                    Direct conversations with people who were not logged in
                  </li>
                  <li data-i18n="data.account.item.state">
                    Read markers, encryption devices, and messages waiting for
                    them
                  </li>
                </ul>
                <p class="data-text muted" data-i18n="data.account.kept">
                  Not deleted: messages sent without being logged in, shared
                  files and voice messages (they are not linked to an account),
                  and copies on other servers of this network. Ask the server's
                  administrator about those.
                </p>
                <form id="delete-account-form" class="data-form" novalidate>
                  <div class="setting-row stacked">
                    <label for="del-account" data-i18n="data.account.name">
                      Account
                    </label>
                    <input
                      type="text"
                      id="del-account"
                      autocomplete="username"
                      autocapitalize="none"
                      spellcheck={false}
                      maxLength={64}
                    />
                  </div>
                  <div class="setting-row stacked">
                    <label for="del-password" data-i18n="data.account.password">
                      Password
                    </label>
                    <input
                      type="password"
                      id="del-password"
                      autocomplete="current-password"
                      maxLength={1024}
                    />
                  </div>
                  <label class="setting-check">
                    <input type="checkbox" id="del-understood" />
                    <span data-i18n="data.account.understood">
                      I understand that this cannot be undone.
                    </span>
                  </label>
                  <div
                    class="data-notice hidden"
                    id="del-notice"
                    role="status"
                    aria-live="polite"
                  >
                  </div>
                  <button
                    type="submit"
                    class="danger"
                    id="btn-delete-account"
                    disabled
                    data-i18n="data.account.submit"
                  >
                    Delete my account and data
                  </button>
                </form>
              </section>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
