// Accounts: SASL accounts (Verify or Reset Pass, email, client
// certificates for SASL EXTERNAL, Delete) and a form to create one.
import { useRef, useState } from "preact/hooks";
import type { AccountEntry } from "./api.ts";
import { matchesFilter } from "./format.ts";
import { formKey, submitForm } from "./forms.ts";
import {
  busyKey,
  confirmDelete,
  filterOf,
  isBusy,
  openModal,
  overview,
  runAction,
} from "./store.ts";
import {
  ActionButton,
  FilterInput,
  mono,
  type Row,
  styled,
  Table,
} from "./Table.tsx";

function resetPassword(name: string): void {
  openModal({
    title: `Reset Password for ${name}`,
    label: "New SASL password",
    inputType: "password",
    placeholder: "Enter new password...",
    confirmLabel: "Update Password",
    onConfirm: (pass) => void runAction("reset-password", [name, pass]),
  });
}

function editEmail(a: AccountEntry): void {
  openModal({
    title: `Email for ${a.name}`,
    message: "Used for verification codes. Leave blank to remove it.",
    label: "Email address",
    inputType: "email",
    value: a.email ?? "",
    placeholder: "name@example.org",
    allowEmpty: true,
    confirmLabel: "Save Email",
    onConfirm: (email) =>
      void runAction("set-email", email ? [a.name, email] : [a.name]),
  });
}

/** 64 hex digits, with or without ":" separators. */
function validFingerprint(text: string): boolean {
  return /^[0-9a-f]{64}$/i.test(text.trim().replace(/:/g, ""));
}

/** Client certificate fingerprints of one account (SASL EXTERNAL). */
function CertPanel(
  { a, onClose }: { a: AccountEntry; onClose: () => void },
) {
  const [draft, setDraft] = useState("");
  const list = a.certfp_list ?? [];
  const busy = busyKey("certs", a.name);
  const add = async (ev: Event) => {
    ev.preventDefault();
    if (!validFingerprint(draft)) return;
    const ok = await runAction("add-certfp", [a.name, draft.trim()], {
      key: busy,
    });
    if (ok) setDraft("");
  };
  return (
    <section
      class="panel cert-panel"
      id="cert-panel"
      aria-labelledby="cert-panel-title"
    >
      <div class="chan-editor-head">
        <div>
          <h3 id="cert-panel-title">
            Client certificates for <code>{a.name}</code>
          </h3>
          <p class="muted control-desc">
            A TLS client certificate with one of these SHA-256 fingerprints logs
            in to this account with SASL EXTERNAL.
          </p>
        </div>
        <button type="button" class="small" onClick={onClose}>
          Close
        </button>
      </div>
      {list.length === 0
        ? <p class="muted chan-empty">No certificates.</p>
        : (
          <ul class="mask-chips">
            {list.map((fp) => (
              <li key={fp} class="mask-chip">
                <code title={fp}>{fp}</code>
                <button
                  type="button"
                  class="chip-remove"
                  aria-label={`Remove certificate ${fp.slice(0, 16)}…`}
                  title="Remove"
                  disabled={isBusy(busy)}
                  onClick={() =>
                    void runAction("remove-certfp", [a.name, fp], {
                      key: busy,
                    })}
                >
                  ×
                </button>
              </li>
            ))}
          </ul>
        )}
      <form class="inline-form compact" onSubmit={add}>
        <input
          type="text"
          class="fp-input"
          placeholder="SHA-256 fingerprint (openssl x509 -fingerprint -sha256)"
          aria-label="Certificate fingerprint"
          aria-invalid={draft && !validFingerprint(draft) ? "true" : undefined}
          spellcheck={false}
          autocomplete="off"
          value={draft}
          onInput={(ev) => setDraft(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="small"
          busyKey={busy}
          disabled={!validFingerprint(draft)}
        >
          Add
        </ActionButton>
      </form>
    </section>
  );
}

function deleteAccount(name: string): void {
  confirmDelete(
    `Delete account ${name}?`,
    "The account, its credentials, and its certificate fingerprints are removed. This cannot be undone.",
    "Delete Account",
    () => void runAction("delete-account", [name]),
  );
}

export function AccountsTab() {
  const [name, setName] = useState("");
  const [pass, setPass] = useState("");
  const [email, setEmail] = useState("");
  const [certsOf, setCertsOf] = useState<string | null>(null);
  const nameRef = useRef<HTMLInputElement>(null);

  const q = filterOf("accounts");
  const accounts = (overview.value?.accounts?.accounts ?? []).filter((a) =>
    matchesFilter(
      q,
      a.name,
      a.email,
      a.verified === false ? "pending" : "verified",
    )
  );
  const rows: Row[] = accounts.map((a) => ({
    key: a.name,
    cells: [
      mono(a.name),
      a.verified === false
        ? styled("pending", "state-warn")
        : styled("verified", "state-ok"),
      <button
        key="email"
        type="button"
        class="link-button cell-edit"
        title="Change email"
        onClick={() => editEmail(a)}
      >
        {a.email || "add email"}
      </button>,
      <button
        key="certs"
        type="button"
        class="link-button cell-edit"
        aria-expanded={certsOf === a.name ? "true" : "false"}
        aria-controls="cert-panel"
        onClick={() => setCertsOf(certsOf === a.name ? null : a.name)}
      >
        {a.certfps ?? 0}{" "}
        {(a.certfps ?? 0) === 1 ? "certificate" : "certificates"}
      </button>,
      <span key="cell" class="action-row">
        {a.verified === false
          ? (
            <ActionButton
              class="primary small"
              busyKey={busyKey("verify-account", a.name)}
              onClick={() => void runAction("verify-account", [a.name])}
            >
              Verify
            </ActionButton>
          )
          : (
            <ActionButton
              class="small"
              busyKey={busyKey("reset-password", a.name)}
              onClick={() => resetPassword(a.name)}
            >
              Reset Pass
            </ActionButton>
          )}
        <ActionButton
          class="danger small"
          busyKey={busyKey("delete-account", a.name)}
          onClick={() => {
            if (certsOf === a.name) setCertsOf(null);
            deleteAccount(a.name);
          }}
        >
          Delete
        </ActionButton>
      </span>,
    ],
  }));

  const onSubmit = (ev: Event) => {
    ev.preventDefault();
    const n = name.trim();
    const e = email.trim();
    const args = !n || !pass ? null : e ? [n, pass, e] : [n, pass];
    void submitForm("create-account", args, () => {
      setName("");
      setPass("");
      setEmail("");
      nameRef.current?.focus();
    });
  };

  return (
    <>
      <div class="page-head">
        <h2>SASL Accounts</h2>
        <FilterInput
          tableKey="accounts"
          placeholder="Filter by account, email, status..."
        />
      </div>
      <form class="inline-form" id="form-account" onSubmit={onSubmit}>
        <input
          ref={nameRef}
          type="text"
          id="inp-acct-name"
          placeholder="Account name"
          required
          value={name}
          onInput={(ev) => setName(ev.currentTarget.value)}
        />
        <input
          type="password"
          id="inp-acct-pass"
          placeholder="Password"
          required
          value={pass}
          onInput={(ev) => setPass(ev.currentTarget.value)}
        />
        <input
          type="email"
          id="inp-acct-email"
          placeholder="Email (optional)"
          value={email}
          onInput={(ev) => setEmail(ev.currentTarget.value)}
        />
        <ActionButton
          type="submit"
          class="primary"
          busyKey={formKey("create-account")}
        >
          Create Account
        </ActionButton>
      </form>
      {certsOf && (() => {
        const a = (overview.value?.accounts?.accounts ?? []).find((x) =>
          x.name === certsOf
        );
        return a
          ? <CertPanel key={a.name} a={a} onClose={() => setCertsOf(null)} />
          : null;
      })()}
      <div id="accounts-wrap">
        <Table
          tableKey="accounts"
          headers={["Account", "Status", "Email", "Certificates", "Action"]}
          rows={rows}
          emptyText="No accounts yet."
        />
      </div>
    </>
  );
}
