// End-to-end encryption manager wiring and its settings tab.
import { byId as $, errorMessage } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { E2eeManager } from "../e2ee/manager.ts";
import { addLine } from "./buffers.ts";
import { sendRaw } from "./connection.ts";
import { renderBuffers } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { isChan } from "./util.ts";

export const e2ee = new E2eeManager({
  sendRaw: (line) => sendRaw(line),
  onDecrypted: (ev) => {
    addLine(ev.target, {
      time: ev.time,
      nick: ev.nick,
      text: ev.text,
      encrypted: true,
    });
  },
  onNotice: (target, text, kind) => {
    addLine(target, { text, kind });
  },
  onStateChange: () => {
    updateE2eeUi();
    renderBuffers();
    if ($("settings-modal").classList.contains("open")) renderE2eeModal();
  },
});

export function updateE2eeUi(): void {
  const buf = buffers.get(S.activeBuf);
  const btn = $("btn-e2ee");
  const form = $("send-form");
  const inp = $<HTMLTextAreaElement>("inp-msg");
  if (!buf || buf.name === "*status") {
    btn.style.display = "none";
    form.classList.remove("e2ee-active");
    inp.placeholder = t("ph.msg");
    return;
  }
  btn.style.display = "inline-flex";
  const on = e2ee.isBufferEncrypted(buf.name);
  const ready = e2ee.isReady();
  btn.classList.toggle("on", on);
  btn.setAttribute("aria-pressed", String(on));
  $("btn-e2ee-label").textContent = on ? t("e2ee.on") : t("e2ee.off");
  if (!ready) {
    btn.title = e2ee.isServerSupported()
      ? t("e2ee.banner.noacct")
      : t("e2ee.banner.unsupported");
  } else {
    btn.title = on ? t("e2ee.on") : t("e2ee.off");
  }
  form.classList.toggle("e2ee-active", on);
  inp.placeholder = on
    ? t("ph.msg.e2ee", { target: buf.name })
    : t("ph.msg.to", { target: buf.name });
}

export function renderE2eeModal(): void {
  const st = e2ee.getStatus();
  const banner = $("e2ee-status-banner");
  banner.className = "e2ee-status-banner";
  if (!st.serverSupported) {
    banner.classList.add("warn");
    banner.textContent = t("e2ee.banner.unsupported");
  } else if (!st.account) {
    banner.classList.add("warn");
    banner.textContent = t("e2ee.banner.noacct");
  } else if (!st.bound) {
    banner.textContent = t("e2ee.banner.binding");
  } else {
    banner.classList.add("ok");
    banner.textContent = t("e2ee.banner.active");
  }

  $("e2ee-account").textContent = st.account || "-";
  $("e2ee-device").textContent = st.deviceId ? String(st.deviceId) : "-";
  $("e2ee-prekeys").textContent = st.bound ? String(st.prekeyCount) : "-";
  $("e2ee-sessions").textContent = String(st.sessionCount);
  $("e2ee-fingerprint").textContent = st.fingerprint || "-";

  const buf = buffers.get(S.activeBuf);
  const canRotate = st.bound && !!buf && isChan(buf.name);
  $<HTMLButtonElement>("btn-e2ee-export").disabled = !st.account;
  $<HTMLButtonElement>("btn-e2ee-import").disabled = !st.account;
  $<HTMLButtonElement>("btn-e2ee-rotate").disabled = !canRotate;
  $<HTMLButtonElement>("btn-e2ee-replenish").disabled = !st.bound;
  $<HTMLButtonElement>("btn-e2ee-reset").disabled = !st.account;

  const peersEl = $("e2ee-peers");
  peersEl.textContent = "";
  if (st.trustedPeers.length === 0) {
    const empty = document.createElement("div");
    empty.className = "e2ee-empty";
    empty.textContent = t("e2ee.peers.empty");
    peersEl.appendChild(empty);
  } else {
    for (const p of st.trustedPeers) {
      const row = document.createElement("div");
      row.className = "e2ee-peer-row";
      const info = document.createElement("div");
      info.className = "e2ee-peer-info";
      const title = document.createElement("div");
      title.className = "peer-id";
      title.textContent = `${p.account} (${p.device})`;
      const sn = document.createElement("div");
      sn.className = "peer-sn";
      sn.dir = "ltr";
      sn.textContent = p.safetyNumber;
      info.appendChild(title);
      info.appendChild(sn);

      const forget = document.createElement("button");
      forget.type = "button";
      forget.className = "small";
      forget.textContent = t("e2ee.forget");
      forget.title = "Forget pinned identity key and session for this device";
      forget.onclick = () => {
        e2ee.forgetPeer(p.key);
        renderE2eeModal();
      };
      row.appendChild(info);
      row.appendChild(forget);
      peersEl.appendChild(row);
    }
  }
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-e2ee").onclick = () => {
    const buf = buffers.get(S.activeBuf);
    if (!buf || buf.name === "*status") return;
    const on = e2ee.toggleBuffer(buf.name);
    if (e2ee.isReady()) {
      addLine(buf.name, {
        text: on
          ? "End-to-end encryption enabled for this conversation."
          : "End-to-end encryption disabled for this conversation.",
        kind: "sys",
      });
    }
  };

  $("btn-e2ee-export").onclick = () => {
    const pass = prompt(
      "Enter a passphrase (min 6 characters) to encrypt your E2EE key backup:",
    );
    if (pass === null) return;
    try {
      const { filename, content } = e2ee.exportBackup(pass);
      const blob = new Blob([content], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      addLine("*status", {
        text: `Downloaded encrypted E2EE key backup (${filename}).`,
        kind: "sys",
      });
    } catch (err) {
      alert(errorMessage(err));
    }
  };

  $("btn-e2ee-import").onclick = () => {
    const fileInp = $<HTMLInputElement>("inp-e2ee-file");
    fileInp.value = "";
    fileInp.click();
  };

  $<HTMLInputElement>("inp-e2ee-file").onchange = async (ev) => {
    const input = ev.target as HTMLInputElement;
    const file = input.files && input.files[0];
    if (!file) return;
    const pass = prompt("Enter the passphrase for this E2EE key backup:");
    if (pass === null) return;
    try {
      const text = await file.text();
      const res = e2ee.importBackup(text, pass);
      renderE2eeModal();
      addLine("*status", {
        text:
          `Imported E2EE keys for ${res.account} (device ${res.deviceId}) and re-binding...`,
        kind: "sys",
      });
    } catch (err) {
      alert(errorMessage(err));
    }
  };

  $("btn-e2ee-replenish").onclick = () => {
    e2ee.replenishPrekeys(20);
    addLine("*status", {
      text: "Uploaded 20 fresh E2EE one-time prekeys.",
      kind: "sys",
    });
  };

  $("btn-e2ee-rotate").onclick = () => {
    const buf = buffers.get(S.activeBuf);
    if (buf && isChan(buf.name)) void e2ee.rotateChannelKey(buf.name);
  };

  $("btn-e2ee-reset").onclick = () => {
    if (
      confirm(
        "Reset your E2EE device keys and sessions? Peers will see a new identity key.",
      )
    ) {
      e2ee.resetDevice();
      renderE2eeModal();
    }
  };
}
