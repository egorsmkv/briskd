// Create an IRC (SASL) account: POST /api/signup.
import { useState } from "preact/hooks";
import { errorMessage, postJson } from "../../../common/dom.ts";
import {
  AltchaField,
  AuthCard,
  Field,
  Notice,
  type NoticeState,
  useAltcha,
} from "../../components/auth.tsx";
import { config } from "../../config.ts";

interface SignupResponse {
  status?: string;
  account?: string;
  message?: string;
  error?: string;
}

export default function SignupPage() {
  const cfg = config();
  const [notice, setNotice] = useState<NoticeState | null>(null);
  const [account, setAccount] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [terms, setTerms] = useState(false);
  const [busy, setBusy] = useState(false);
  const altcha = useAltcha((text) => setNotice({ ok: false, text }));

  const submit = async (ev: Event) => {
    ev.preventDefault();
    if (password !== confirm) {
      return setNotice({ ok: false, text: "Passwords do not match." });
    }
    if (!terms) {
      return setNotice({
        ok: false,
        text: "You must accept the Terms of Use and Privacy Policy.",
      });
    }
    if (!altcha.payload) {
      return setNotice({
        ok: false,
        text: "Please complete the ALTCHA verification.",
      });
    }
    setBusy(true);
    try {
      const payload: Record<string, unknown> = {
        account: account.trim(),
        password,
        accept_terms: true,
        altcha: altcha.payload,
      };
      if (email.trim()) payload.email = email.trim();
      const { ok, data } = await postJson<SignupResponse>(
        "/api/signup",
        payload,
      );
      if (ok) {
        setNotice({
          ok: true,
          text: data.status === "verification_required"
            ? `Account '${data.account}' created. Check your email for the verification link or code.`
            : `Account '${data.account}' created. You can now log in via SASL in your IRC client.`,
        });
        setAccount("");
        setEmail("");
        setPassword("");
        setConfirm("");
        setTerms(false);
      } else {
        setNotice({
          ok: false,
          text: data.message || data.error || "Sign up failed.",
        });
      }
    } catch (err) {
      setNotice({ ok: false, text: `Request failed: ${errorMessage(err)}` });
    } finally {
      altcha.reset();
      setBusy(false);
    }
  };

  return (
    <AuthCard
      title="Create IRC Account"
      sub="Register an account for SASL authentication on this IRC server."
      links={
        <>
          Already have a code? <a href="/verify">Verify your account</a> ·{" "}
          <a href="/">Open WebIRC</a>
        </>
      }
    >
      <Notice notice={notice} />
      <form id="signup-form" onSubmit={submit}>
        <Field
          id="account"
          label="Account name"
          autocomplete="username"
          required
          maxLength={64}
          value={account}
          onInput={setAccount}
        />
        <Field
          id="email"
          type="email"
          label={
            <>
              Email <span class="muted">(if required by server)</span>
            </>
          }
          autocomplete="email"
          maxLength={254}
          value={email}
          onInput={setEmail}
        />
        <Field
          id="password"
          type="password"
          label="Password"
          autocomplete="new-password"
          required
          maxLength={256}
          value={password}
          onInput={setPassword}
        />
        <Field
          id="confirm"
          type="password"
          label="Confirm password"
          autocomplete="new-password"
          required
          maxLength={256}
          value={confirm}
          onInput={setConfirm}
        />
        <div class="field">
          <label class="checkbox-label">
            <input
              type="checkbox"
              id="accept-terms"
              required
              checked={terms}
              onChange={(ev) => setTerms(ev.currentTarget.checked)}
            />
            <span>
              I accept the{" "}
              <a href={cfg.termsUrl} target="_blank" rel="noopener noreferrer">
                Terms of Use
              </a>{" "}
              and{" "}
              <a
                href={cfg.privacyUrl}
                target="_blank"
                rel="noopener noreferrer"
              >
                Privacy Policy
              </a>
              .
            </span>
          </label>
        </div>
        <AltchaField altcha={altcha} id="altcha-check" />
        <button
          type="submit"
          class="primary btn-full"
          id="btn-submit"
          disabled={busy}
        >
          Create Account
        </button>
      </form>
    </AuthCard>
  );
}
