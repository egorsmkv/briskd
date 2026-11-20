// Right sidebar: channel members with a filter.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.

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
              class="small"
              id="btn-close-right"
              aria-label="Close members"
            >
              ×
            </button>
          </div>
          <input
            type="text"
            id="inp-member-filter"
            dir="auto"
            placeholder="Filter members..."
            data-i18n-placeholder="ph.filter.members"
          />
        </div>
        <div id="members-list"></div>
      </aside>
    </>
  );
}
