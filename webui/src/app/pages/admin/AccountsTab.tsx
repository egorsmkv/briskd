// Accounts: SASL accounts (Verify or Reset Pass, Delete) and a form to
// create one.
import { useRef, useState } from "preact/hooks";
import { matchesFilter } from "./format.ts";
import { formKey, submitForm } from "./forms.ts";
import {
  busyKey,
  confirmDelete,
  filterOf,
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
      a.email || "-",
      a.certfps ?? 0,
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
          onClick={() => deleteAccount(a.name)}
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
      <div id="accounts-wrap">
        <Table
          tableKey="accounts"
          headers={["Account", "Status", "Email", "CertFPs", "Action"]}
          rows={rows}
          emptyText="No accounts yet."
        />
      </div>
    </>
  );
}
