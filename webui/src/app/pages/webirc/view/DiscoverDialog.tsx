// Browse the server's channel list.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { Icon } from "../../../components/Icon.tsx";

export function DiscoverDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="discover-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="discover-modal-title"
      >
        <div class="modal-card modal-wide">
          <div class="modal-head">
            <h2 id="discover-modal-title" data-i18n="discover.title">
              Discover Channels
            </h2>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-discover"
              aria-label="Close channel discovery"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <div class="modal-body">
            <div class="discover-toolbar">
              <input
                type="search"
                id="inp-discover-filter"
                dir="auto"
                placeholder="Filter channels or topics..."
                data-i18n-placeholder="discover.search"
              />
              <button
                type="button"
                class="small"
                id="btn-discover-refresh"
                data-i18n="discover.refresh"
              >
                Refresh
              </button>
            </div>
            <div class="discover-list" id="discover-list"></div>
          </div>
        </div>
      </div>
    </>
  );
}
