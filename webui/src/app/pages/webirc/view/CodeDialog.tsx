// Share a code snippet.
// Markup only: the WebIRC controllers (webui/src/webirc/) find these
// elements by id and wire them when the chat starts.

export function CodeDialog() {
  return (
    <>
      <div
        class="modal-backdrop"
        id="code-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="code-modal-title"
      >
        <div class="modal-card modal-wide">
          <div class="modal-head">
            <h2 id="code-modal-title" data-i18n="code.modal.title">
              Share Code Snippet
            </h2>
            <button
              type="button"
              class="small"
              id="btn-close-code"
              aria-label="Close code modal"
            >
              ×
            </button>
          </div>
          <form class="modal-body" id="code-form">
            <div class="code-form-row">
              <select id="sel-code-lang" aria-label="Language">
                <option value="text">Plain Text</option>
                <option value="erlang">Erlang</option>
                <option value="typescript">TypeScript</option>
                <option value="javascript">JavaScript</option>
                <option value="python">Python</option>
                <option value="rust">Rust</option>
                <option value="go">Go</option>
                <option value="bash">Bash / Shell</option>
                <option value="sql">SQL</option>
                <option value="json">JSON</option>
                <option value="html">HTML</option>
                <option value="css">CSS</option>
              </select>
              <input
                type="text"
                id="inp-code-title"
                maxlength={80}
                placeholder="Filename or title (optional)"
                data-i18n-placeholder="code.modal.titlePh"
              />
            </div>
            <textarea
              id="inp-code-body"
              dir="ltr"
              rows={12}
              spellcheck={false}
              placeholder="Paste your code here... (Ctrl+Enter to send)"
              data-i18n-placeholder="code.modal.bodyPh"
              required
            >
            </textarea>
            <div class="e2ee-actions">
              <button type="submit" class="primary" data-i18n="code.modal.send">
                Send Snippet
              </button>
              <button
                type="button"
                id="btn-cancel-code"
                data-i18n="voice.cancel"
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
