// Channel moderation: modes, bans, kicks.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { Icon } from "../../../components/Icon.tsx";

export function ModerationDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="mod-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="mod-modal-title"
      >
        <div class="modal-card modal-wide">
          <div class="modal-head">
            <h2 id="mod-modal-title" data-i18n="mod.title">
              Channel Moderation
            </h2>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-mod"
              aria-label="Close moderation tools"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <div class="modal-body">
            <div class="setting-group">
              <div class="setting-label" data-i18n="mod.modes">
                Channel Modes
              </div>
              <div class="mod-mode-grid" id="mod-mode-grid"></div>
            </div>
            <div class="setting-group">
              <div class="setting-label" data-i18n="mod.invite">
                Invite User
              </div>
              <form class="mod-inline-form" id="mod-invite-form">
                <input
                  type="text"
                  id="inp-mod-invite"
                  placeholder="Nickname"
                  autocomplete="off"
                  required
                />
                <button
                  type="submit"
                  class="small primary"
                  data-i18n="mod.invite.btn"
                >
                  Invite
                </button>
              </form>
            </div>
            <div class="setting-group">
              <div class="setting-label" data-i18n="mod.notice">
                Channel Notice
              </div>
              <form class="mod-inline-form" id="mod-notice-form">
                <input
                  type="text"
                  id="inp-mod-notice"
                  dir="auto"
                  placeholder="Announcement to channel..."
                  autocomplete="off"
                  required
                />
                <button
                  type="submit"
                  class="small primary"
                  data-i18n="mod.notice.btn"
                >
                  Send Notice
                </button>
              </form>
            </div>
            <div class="setting-group">
              <div class="setting-label" data-i18n="mod.bans">
                Ban List (+b)
              </div>
              <form class="mod-inline-form" id="mod-ban-form">
                <input
                  type="text"
                  id="inp-mod-ban"
                  placeholder="nick!*@* or *!*@host"
                  autocomplete="off"
                  required
                />
                <button
                  type="submit"
                  class="small danger"
                  data-i18n="mod.ban.btn"
                >
                  Ban Mask
                </button>
              </form>
              <div class="mod-ban-list" id="mod-ban-list"></div>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
