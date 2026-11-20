// Building blocks of the account pages (sign-up, verify, recover): the card
// layout with a theme toggle, the status notice, and the ALTCHA checkbox.
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { solveAltcha } from "../../common/altcha.ts";
import { errorMessage } from "../../common/dom.ts";
import { initTheme } from "../../common/theme.ts";

export interface NoticeState {
  ok: boolean;
  text: string;
}

export function Notice({ notice }: { notice: NoticeState | null }) {
  return (
    <div
      id="notice"
      class={notice ? (notice.ok ? "ok" : "err") : ""}
      role="status"
      aria-live="polite"
    >
      {notice?.text ?? ""}
    </div>
  );
}

function ThemeButton() {
  const ref = useRef<HTMLButtonElement>(null);
  // The theme module labels the button and toggles light/dark on click.
  useEffect(() => {
    initTheme([ref.current]);
  }, []);
  return (
    <button
      type="button"
      class="small"
      id="btn-theme"
      ref={ref}
      aria-label="Toggle dark mode"
    >
      Dark
    </button>
  );
}

export function AuthCard(
  { title, sub, children, links }: {
    title: string;
    sub: string;
    children: ComponentChildren;
    links: ComponentChildren;
  },
) {
  return (
    <main class="card">
      <div class="top">
        <h1>{title}</h1>
        <ThemeButton />
      </div>
      <p class="sub">{sub}</p>
      {children}
      <p class="foot-links">{links}</p>
    </main>
  );
}

/** The ALTCHA proof-of-work state of one form. */
export interface Altcha {
  payload: string | null;
  busy: boolean;
  /** Clear it (after each submission: a payload is single-use). */
  reset(): void;
  /** Solve on check, clear on uncheck. */
  toggle(checked: boolean): void;
}

export function useAltcha(onError: (msg: string) => void): Altcha {
  const [payload, setPayload] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const generation = useRef(0);
  const reset = () => {
    generation.current++;
    setPayload(null);
    setBusy(false);
  };
  const toggle = (checked: boolean) => {
    if (!checked) return reset();
    const gen = ++generation.current;
    setBusy(true);
    solveAltcha().then((p) => {
      if (gen === generation.current) setPayload(p);
    }).catch((err) => {
      if (gen !== generation.current) return;
      setPayload(null);
      onError(`ALTCHA error: ${errorMessage(err)}`);
    }).finally(() => {
      if (gen === generation.current) setBusy(false);
    });
  };
  return { payload, busy, reset, toggle };
}

export function AltchaField({ altcha, id }: { altcha: Altcha; id: string }) {
  const label = altcha.busy
    ? "Verifying..."
    : altcha.payload
    ? "Verified"
    : "I'm not a robot";
  return (
    <div class="field">
      <div class="altcha-box">
        <label class="altcha-left" for={id}>
          <input
            type="checkbox"
            id={id}
            checked={altcha.busy || altcha.payload !== null}
            disabled={altcha.busy}
            onChange={(ev) => altcha.toggle(ev.currentTarget.checked)}
          />
          <span>{label}</span>
        </label>
        <a
          class="altcha-brand"
          href="https://altcha.org/"
          target="_blank"
          rel="noopener noreferrer"
        >
          ALTCHA
        </a>
      </div>
    </div>
  );
}

/** A labelled input bound to a string state. */
export function Field(
  props: {
    id: string;
    label: ComponentChildren;
    value: string;
    onInput: (v: string) => void;
    type?: string;
    autocomplete?: string;
    required?: boolean;
    maxLength?: number;
    placeholder?: string;
  },
) {
  return (
    <div class="field">
      <label for={props.id}>{props.label}</label>
      <input
        type={props.type ?? "text"}
        id={props.id}
        name={props.id}
        autocomplete={props.autocomplete}
        required={props.required}
        maxLength={props.maxLength}
        placeholder={props.placeholder}
        value={props.value}
        onInput={(ev) => props.onInput(ev.currentTarget.value)}
      />
    </div>
  );
}

/** URL query parameter `name` of the current page ("" when absent). */
export function queryParam(name: string): string {
  return new URLSearchParams(location.search).get(name)?.slice(0, 254) ?? "";
}
