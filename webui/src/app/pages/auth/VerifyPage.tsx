// Verify an account with the emailed code: POST /api/verify. The link in the
// email carries ?account= (or ?email=) and ?code=, which prefill the form.
import { useState } from "preact/hooks";
import { errorMessage, postJson } from "../../../common/dom.ts";
import {
  AltchaField,
  AuthCard,
  Field,
  Notice,
  type NoticeState,
  queryParam,
  useAltcha,
} from "../../components/auth.tsx";

interface VerifyResponse {
  account?: string;
  message?: string;
  error?: string;
}

export default function VerifyPage() {
  const [notice, setNotice] = useState<NoticeState | null>(null);
  const [account, setAccount] = useState(queryParam("account"));
  const [email, setEmail] = useState(queryParam("email"));
  const [code, setCode] = useState(queryParam("code"));
  const [busy, setBusy] = useState(false);
  const altcha = useAltcha((text) => setNotice({ ok: false, text }));

  const submit = async (ev: Event) => {
    ev.preventDefault();
    if (!email.trim() && !account.trim()) {
      return setNotice({ ok: false, text: "Enter your email address." });
    }
    if (!altcha.payload) {
      return setNotice({
        ok: false,
        text: "Please complete the ALTCHA verification.",
      });
    }
    setBusy(true);
    try {
      const payload: Record<string, string> = {
        code: code.trim(),
        altcha: altcha.payload,
      };
      if (email.trim()) payload.email = email.trim();
      else payload.account = account.trim();
      const { ok, data } = await postJson<VerifyResponse>(
        "/api/verify",
        payload,
      );
      if (ok) {
        setNotice({
          ok: true,
          text:
            `Account '${data.account}' has been verified. You can now log in via SASL.`,
        });
        setAccount("");
        setEmail("");
        setCode("");
      } else {
        setNotice({
          ok: false,
          text: data.message || data.error || "Verification failed.",
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
      title="Verify IRC Account"
      sub="Paste your email address and the verification code from your email."
      links={
        <>
          Need an account? <a href="/signup">Sign up</a> ·{" "}
          <a href="/">Open WebIRC</a>
        </>
      }
    >
      <Notice notice={notice} />
      <form id="verify-form" onSubmit={submit}>
        <Field
          id="email"
          type="email"
          label="Email address"
          autocomplete="email"
          maxLength={254}
          placeholder={account && !email
            ? `Using account: ${account}`
            : "you@example.com"}
          value={email}
          onInput={setEmail}
        />
        <Field
          id="code"
          label="Verification code"
          autocomplete="one-time-code"
          required
          maxLength={64}
          placeholder="Paste verification code"
          value={code}
          onInput={setCode}
        />
        <AltchaField altcha={altcha} id="altcha-check" />
        <button
          type="submit"
          class="primary btn-full"
          id="btn-submit"
          disabled={busy}
        >
          Verify Account
        </button>
      </form>
    </AuthCard>
  );
}
