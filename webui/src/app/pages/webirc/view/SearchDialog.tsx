// Message search (egorsmkv.github.io/search): a query, where to look (the
// open conversation or every conversation), and the matching messages.
// Markup only: webui/src/webirc/search_ui.ts finds these elements by id.
import { Icon } from "../../../components/Icon.tsx";

export function SearchDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="search-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="search-modal-title"
      >
        <div class="modal-card modal-wide">
          <div class="modal-head">
            <h2 id="search-modal-title" data-i18n="search.title">
              Search Messages
            </h2>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-search"
              aria-label="Close search"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <div class="modal-body">
            <form class="search-toolbar" id="search-form" role="search">
              <input
                type="search"
                id="inp-search"
                dir="auto"
                maxLength={300}
                autoComplete="off"
                placeholder="Search messages..."
                data-i18n-placeholder="search.placeholder"
                aria-describedby="search-help"
              />
              <select id="sel-search-scope" aria-label="Where to search">
                <option value="here" id="opt-search-here">
                  This conversation
                </option>
                <option value="all" data-i18n="search.scope.all">
                  All conversations
                </option>
              </select>
              <button
                type="submit"
                class="primary small"
                id="btn-search-go"
                data-i18n="search.go"
              >
                Search
              </button>
            </form>
            <p
              class="muted search-help"
              id="search-help"
              data-i18n="search.help"
            >
              All words must match. Use "quotes" for a phrase, word* for a
              prefix, -word to exclude, and OR between alternatives.
            </p>
            <div
              class="search-status muted"
              id="search-status"
              role="status"
              aria-live="polite"
            >
            </div>
            <ol class="search-results" id="search-results"></ol>
            <button
              type="button"
              class="small hidden"
              id="btn-search-more"
              data-i18n="search.more"
            >
              Load older results
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
