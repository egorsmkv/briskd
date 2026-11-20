// Set the channel topic.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.
import { Icon } from "../../../components/Icon.tsx";

export function TopicDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="topic-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="topic-modal-title"
      >
        <div class="modal-card">
          <div class="modal-head">
            <h2 id="topic-modal-title" data-i18n="topic.modal.title">
              Set Channel Topic
            </h2>
            <button
              type="button"
              class="ghost icon"
              id="btn-close-topic"
              aria-label="Close topic dialog"
            >
              <Icon name="x" size={18} />
            </button>
          </div>
          <form class="modal-body" id="topic-form">
            <div class="field">
              <label for="inp-topic">
                <span data-i18n="topic.modal.label">Topic for</span>{" "}
                <span id="topic-modal-chan" dir="ltr">#channel</span>
              </label>
              <input
                type="text"
                id="inp-topic"
                dir="auto"
                maxlength={390}
                placeholder="Enter channel topic (leave blank to clear)"
                data-i18n-placeholder="topic.modal.ph"
              />
            </div>
            <div class="e2ee-actions">
              <button
                type="submit"
                class="primary small"
                data-i18n="btn.save.topic"
              >
                Save Topic
              </button>
              <button
                type="button"
                class="small"
                id="btn-cancel-topic"
                data-i18n="btn.cancel"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    </>
  );
}
