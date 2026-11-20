// Right sidebar: channel members with a filter.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { Icon } from "../../../components/Icon.tsx";

export function MembersPanel() {
  return (
    <>
      <aside class="sidebar-right" id="sidebar-right">
        <div class="members-head">
          <div class="members-head-top">
            <div
              class="members-title"
              id="members-title"
              data-i18n="members.title"
            >
              Members
            </div>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-right"
              aria-label="Close members"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <label class="members-filter">
            <Icon name="search" size={14} class="icon filter-icon" />
            <input
              type="search"
              id="inp-member-filter"
              dir="auto"
              placeholder="Filter members..."
              aria-label="Filter members"
              data-i18n-placeholder="ph.filter.members"
            />
          </label>
        </div>
        <div id="members-list"></div>
      </aside>
    </>
  );
}
