// The admin dialog: a prompt, a confirmation, or a typed confirmation for
// destructive actions. Focus moves into it on open, Tab cycles inside it,
// Escape or a backdrop click closes it, and focus returns to the opener.
import { useEffect, useRef, useState } from "preact/hooks";
import { closeModal, modal, type ModalState } from "./store.ts";

function ModalForm({ m }: { m: ModalState }) {
  const hasInput = m.label !== undefined;
  const requireText = m.requireText ?? "";
  const isPassword = m.inputType === "password";
  const [value, setValue] = useState(m.value ?? "");
  const [typed, setTyped] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const confirmRef = useRef<HTMLInputElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);

  const entered = isPassword ? value : value.trim();
  const valid = (!requireText || typed.trim() === requireText) &&
    (!hasInput || m.allowEmpty === true || entered !== "");

  useEffect(() => {
    const first = hasInput
      ? inputRef.current
      : requireText
      ? confirmRef.current
      : cancelRef.current;
    first?.focus();
    if (first === inputRef.current && inputRef.current?.value) {
      inputRef.current.select();
    }
  }, []);

  const submit = (ev: Event) => {
    ev.preventDefault();
    if (!valid) return;
    const fn = m.onConfirm;
    closeModal();
    fn(entered);
  };

  return (
    <form class="modal-body" id="admin-modal-form" onSubmit={submit}>
      <p class="modal-message" id="admin-modal-message" hidden={!m.message}>
        {m.message ?? ""}
      </p>
      <div class="modal-field" id="admin-modal-field" hidden={!hasInput}>
        <label for="admin-modal-input" id="admin-modal-label">
          {m.label ?? ""}
        </label>
        <input
          ref={inputRef}
          type={m.inputType || "text"}
          id="admin-modal-input"
          maxLength={400}
          value={value}
          placeholder={m.placeholder ?? ""}
          autocomplete={isPassword ? "new-password" : "off"}
          onInput={(ev) => setValue(ev.currentTarget.value)}
        />
      </div>
      <div
        class="modal-field"
        id="admin-modal-confirm-field"
        hidden={!requireText}
      >
        <label for="admin-modal-confirm-input" id="admin-modal-confirm-label">
          {requireText ? `Type ${requireText} to confirm` : ""}
        </label>
        <input
          ref={confirmRef}
          type="text"
          id="admin-modal-confirm-input"
          maxLength={200}
          autocomplete="off"
          spellcheck={false}
          placeholder={requireText}
          value={typed}
          onInput={(ev) => setTyped(ev.currentTarget.value)}
        />
      </div>
      <div class="modal-actions">
        <button
          type="submit"
          class={m.danger ? "danger" : "primary"}
          id="admin-modal-submit"
          disabled={!valid}
        >
          {m.confirmLabel || "Confirm"}
        </button>
        <button
          type="button"
          id="btn-cancel-modal"
          ref={cancelRef}
          onClick={closeModal}
        >
          Cancel
        </button>
      </div>
    </form>
  );
}

/** Keep Tab and Shift+Tab inside the dialog. */
function trapTab(ev: KeyboardEvent): void {
  if (ev.key !== "Tab") return;
  const box = ev.currentTarget as HTMLElement;
  const focusables = Array.from(
    box.querySelectorAll<HTMLElement>(
      "button:not(:disabled), input:not([hidden])",
    ),
  ).filter((n) => n.offsetParent !== null);
  if (focusables.length === 0) return;
  const first = focusables[0];
  const last = focusables[focusables.length - 1];
  if (ev.shiftKey && document.activeElement === first) {
    ev.preventDefault();
    last.focus();
  } else if (!ev.shiftKey && document.activeElement === last) {
    ev.preventDefault();
    first.focus();
  }
}

export function Modal() {
  const m = modal.value;
  // Close on a backdrop click only when the press also started on the
  // backdrop, so selecting text and releasing outside does not dismiss it.
  const backdropPress = useRef(false);

  useEffect(() => {
    if (!m) return;
    document.body.classList.add("modal-open");
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === "Escape") {
        ev.preventDefault();
        closeModal();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.classList.remove("modal-open");
    };
  }, [m !== null]);

  return (
    <div
      class={m ? "modal-backdrop open" : "modal-backdrop"}
      id="admin-modal"
      role="dialog"
      aria-modal="true"
      aria-labelledby="admin-modal-title"
      onMouseDown={(ev) => {
        backdropPress.current = ev.target === ev.currentTarget;
      }}
      onClick={(ev) => {
        if (backdropPress.current && ev.target === ev.currentTarget) {
          closeModal();
        }
        backdropPress.current = false;
      }}
      onKeyDown={trapTab}
    >
      {m && (
        <div class="modal-card">
          <div class="modal-head">
            <h2 id="admin-modal-title">{m.title}</h2>
            <button
              type="button"
              class="small"
              id="btn-close-modal"
              aria-label="Close dialog"
              onClick={closeModal}
            >
              ×
            </button>
          </div>
          <ModalForm key={m.id} m={m} />
        </div>
      )}
    </div>
  );
}
