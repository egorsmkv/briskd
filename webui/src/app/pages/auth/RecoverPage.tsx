// Password recovery in two steps: request a code by email
// (POST /api/recover/request), then set a new password with it
// (POST /api/recover/confirm). A link with ?code= opens step 2.
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

interface RecoverResponse {
  account?: string;
  message?: string;
  error?: string;
}

type Step = "request" | "confirm";

export default function RecoverPage() {
  const initialCode = queryParam("code");
  const [step, setStep] = useState<Step>(initialCode ? "confirm" : "request");
  const [notice, setNotice] = useState<NoticeState | null>(null);
  const [reqEmail, setReqEmail] = useState(queryParam("email"));
  const [email, setEmail] = useState(queryParam("email"));
  const [code, setCode] = useState(initialCode);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const fail = (text: string) => setNotice({ ok: false, text });
  const altchaReq = useAltcha(fail);
  const altchaCfm = useAltcha(fail);

  const request = async (ev: Event) => {
    ev.preventDefault();
    if (!reqEmail.trim()) return fail("Enter your email address.");
    if (!altchaReq.payload) {
      return fail("Please complete the ALTCHA verification.");
    }
    setBusy(true);
    try {
      const { ok, data } = await postJson<RecoverResponse>(
        "/api/recover/request",
        { email: reqEmail.trim(), altcha: altchaReq.payload },
      );
      if (ok) {
        setNotice({
          ok: true,
          text: data.message ||
            "If an account exists for that email, a recovery code has been sent.",
        });
        setEmail(reqEmail.trim());
        setStep("confirm");
      } else {
        fail(data.message || data.error || "Could not send recovery email.");
      }
    } catch (err) {
      fail(`Request failed: ${errorMessage(err)}`);
    } finally {
      altchaReq.reset();
      setBusy(false);
    }
  };

  const reset = async (ev: Event) => {
    ev.preventDefault();
    if (password !== confirm) return fail("Passwords do not match.");
    if (!altchaCfm.payload) {
      return fail("Please complete the ALTCHA verification.");
    }
    setBusy(true);
    try {
      const { ok, data } = await postJson<RecoverResponse>(
        "/api/recover/confirm",
        {
          email: email.trim(),
          code: code.trim(),
          password,
          altcha: altchaCfm.payload,
        },
      );
      if (ok) {
        setNotice({
          ok: true,
          text:
            `Password updated for account '${data.account}'. You can now log in via SASL.`,
        });
        setCode("");
        setPassword("");
        setConfirm("");
      } else {
        fail(data.message || data.error || "Password reset failed.");
      }
    } catch (err) {
      fail(`Request failed: ${errorMessage(err)}`);
    } finally {
      altchaCfm.reset();
      setBusy(false);
    }
  };

  const tab = (id: Step, label: string) => (
    <button
      type="button"
      class={"step-tab" + (step === id ? " active" : "")}
      id={`tab-${id}`}
      role="tab"
      aria-selected={step === id}
      onClick={() => setStep(id)}
    >
      {label}
    </button>
  );

  return (
    <AuthCard
      title="Recover Password"
      sub="Reset your IRC account password via your verified email address."
      links={
        <>
          <a href="/">Open WebIRC</a> · <a href="/signup">Create account</a> ·
          {" "}
          <a href="/verify">Verify account</a>
        </>
      }
    >
      <div class="step-tabs" role="tablist">
        {tab("request", "1. Request Code")}
        {tab("confirm", "2. Reset Password")}
      </div>
      <Notice notice={notice} />
      {step === "request"
        ? (
          <form
            id="recover-request-form"
            class="step-pane active"
            onSubmit={request}
          >
            <Field
              id="req-email"
              type="email"
              label="Email address"
              autocomplete="email"
              required
              maxLength={254}
              placeholder="you@example.com"
              value={reqEmail}
              onInput={setReqEmail}
            />
            <AltchaField altcha={altchaReq} id="altcha-req-check" />
            <button
              type="submit"
              class="primary btn-full"
              id="btn-req-submit"
              disabled={busy}
            >
              Send Recovery Code
            </button>
          </form>
        )
        : (
          <form
            id="recover-confirm-form"
            class="step-pane active"
            onSubmit={reset}
          >
            <Field
              id="cfm-email"
              type="email"
              label="Email address"
              autocomplete="email"
              required
              maxLength={254}
              placeholder="you@example.com"
              value={email}
              onInput={setEmail}
            />
            <Field
              id="cfm-code"
              label="Recovery code"
              autocomplete="one-time-code"
              required
              maxLength={64}
              placeholder="Paste recovery code from email"
              value={code}
              onInput={setCode}
            />
            <Field
              id="cfm-password"
              type="password"
              label="New password"
              autocomplete="new-password"
              required
              maxLength={256}
              value={password}
              onInput={setPassword}
            />
            <Field
              id="cfm-confirm"
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
              maxLength={256}
              value={confirm}
              onInput={setConfirm}
            />
            <AltchaField altcha={altchaCfm} id="altcha-cfm-check" />
            <button
              type="submit"
              class="primary btn-full"
              id="btn-cfm-submit"
              disabled={busy}
            >
              Reset Password
            </button>
          </form>
        )}
    </AuthCard>
  );
}
