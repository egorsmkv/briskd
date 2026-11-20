// Action results, fixed in a corner so they show however far the page is
// scrolled. Successes fade out (paused while hovered); errors stay until
// dismissed.
import { useEffect, useRef } from "preact/hooks";
import { dismissToast, TOAST_MS, type ToastItem, toasts } from "./store.ts";

function Toast({ t }: { t: ToastItem }) {
  const timer = useRef<number | undefined>(undefined);
  const autoClose = t.kind === "ok" && !t.leaving;

  const schedule = (ms: number) => {
    clearTimeout(timer.current);
    timer.current = setTimeout(() => dismissToast(t.id), ms);
  };

  useEffect(() => {
    if (autoClose) schedule(TOAST_MS);
    return () => clearTimeout(timer.current);
  }, [autoClose]);

  return (
    <div
      class={`toast ${t.kind}${t.leaving ? " leaving" : ""}`}
      role={t.kind === "err" ? "alert" : "status"}
      onMouseEnter={autoClose ? () => clearTimeout(timer.current) : undefined}
      onMouseLeave={autoClose ? () => schedule(TOAST_MS / 2) : undefined}
    >
      <span class="toast-icon" aria-hidden="true">
        {t.kind === "ok" ? "✓" : "!"}
      </span>
      <span class="toast-text">{t.text}</span>
      <button
        type="button"
        class="toast-close"
        aria-label="Dismiss"
        onClick={() => {
          clearTimeout(timer.current);
          dismissToast(t.id);
        }}
      >
        ×
      </button>
    </div>
  );
}

export function Toasts() {
  return (
    <div class="toasts" id="toasts">
      {toasts.value.map((t) => <Toast key={t.id} t={t} />)}
    </div>
  );
}
