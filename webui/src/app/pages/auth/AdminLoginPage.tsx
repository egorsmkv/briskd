// The admin sign-in page (/admin/login): the WebUI administrator's username
// and password from the server's `webui` configuration. A successful
// sign-in sets an HttpOnly session cookie (POST /api/admin/login) and goes
// on to the admin page that sent the user here (?next=), or /admin.
import { useEffect, useRef, useState } from "preact/hooks";
import { errorMessage, postJson } from "../../../common/dom.ts";
import { config } from "../../config.ts";
import {
  AuthCard,
  Notice,
  type NoticeState,
  queryParam,
} from "../../components/auth.tsx";
import { afterLogin } from "../../routes.ts";

interface LoginReply {
  ok?: boolean;
  error?: string;
  message?: string;
  retry_after?: number;
}

function wait(seconds: number): string {
  if (seconds < 60) return `${seconds} second${seconds === 1 ? "" : "s"}`;
  const m = Math.ceil(seconds / 60);
  return `${m} minute${m === 1 ? "" : "s"}`;
}

export default function AdminLoginPage() {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [reveal, setReveal] = useState(false);
  const [caps, setCaps] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<NoticeState | null>(null);
  const userRef = useRef<HTMLInputElement>(null);
  const passRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    userRef.current?.focus();
  }, []);

  const submit = async (ev: Event) => {
    ev.preventDefault();
    if (!username.trim() || !password) {
      setNotice({ ok: false, text: "Enter the username and password." });
      return;
    }
    setBusy(true);
    setNotice(null);
    try {
      const { ok, status, data } = await postJson<LoginReply>(
        "/api/admin/login",
        { username: username.trim(), password },
      );
      if (ok) {
        setNotice({ ok: true, text: "Signed in. Opening the admin panel…" });
        location.assign(afterLogin(queryParam("next")));
        return;
      }
      if (status === 429) {
        setNotice({
          ok: false,
          text: `Too many failed attempts. Try again in ${
            wait(data.retry_after ?? 60)
          }.`,
        });
      } else {
        setNotice({
          ok: false,
          text: data.message || data.error ||
            `Sign-in failed (HTTP ${status}).`,
        });
        setPassword("");
        passRef.current?.focus();
      }
    } catch (err) {
      setNotice({ ok: false, text: `Sign-in failed: ${errorMessage(err)}` });
    } finally {
      setBusy(false);
    }
  };

  const capsCheck = (ev: KeyboardEvent) => {
    setCaps(ev.getModifierState?.("CapsLock") ?? false);
  };

  return (
    <AuthCard
      title="Admin sign in"
      sub={`Manage the ${config().network} server. Use the administrator account from the server's webui configuration.`}
      links={<a href="/">Back to chat</a>}
    >
      <Notice notice={notice} />
      <form id="admin-login-form" onSubmit={submit} method="post" action="#">
        <div class="field">
          <label for="login-username">Username</label>
          <input
            ref={userRef}
            type="text"
            id="login-username"
            name="username"
            autocomplete="username"
            autocapitalize="none"
            spellcheck={false}
            required
            maxLength={256}
            value={username}
            onInput={(ev) => setUsername(ev.currentTarget.value)}
          />
        </div>
        <div class="field">
          <label for="login-password">Password</label>
          <div class="password-row">
            <input
              ref={passRef}
              type={reveal ? "text" : "password"}
              id="login-password"
              name="password"
              autocomplete="current-password"
              required
              maxLength={1024}
              value={password}
              onInput={(ev) => setPassword(ev.currentTarget.value)}
              onKeyUp={capsCheck}
              onKeyDown={capsCheck}
              aria-describedby={caps ? "caps-hint" : undefined}
            />
            <button
              type="button"
              class="reveal"
              aria-pressed={reveal ? "true" : "false"}
              aria-controls="login-password"
              onClick={() => {
                setReveal(!reveal);
                passRef.current?.focus();
              }}
            >
              {reveal ? "Hide" : "Show"}
            </button>
          </div>
          {caps && <p class="caps-hint" id="caps-hint">Caps Lock is on.</p>}
        </div>
        <button
          type="submit"
          class="primary btn-full"
          id="btn-login"
          disabled={busy}
          aria-busy={busy ? "true" : undefined}
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>
      </form>
    </AuthCard>
  );
}
