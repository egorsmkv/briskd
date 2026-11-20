// Topic, moderation, and channel discovery dialogs.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { updateTitle } from "./buffers.ts";
import { calls } from "./calls_ui.ts";
import {
  reconnectNow,
  sendRaw,
  stopHeartbeat,
  stopReconnecting,
} from "./connection.ts";
import { MOD_MODES } from "./files.ts";
import { clearSession } from "./session.ts";
import {
  closeDrawers,
  isOperatorInBuffer,
  renderMembers,
  switchBuf,
} from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { isChan } from "./util.ts";

export function openTopicModal(): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || !isChan(buf.name)) return;
  S.topicTarget = buf.name;
  $("topic-modal-chan").textContent = buf.name;
  const inp = $<HTMLInputElement>("inp-topic");
  inp.value = buf.topic || "";
  $("topic-modal").classList.add("open");
  inp.focus();
  inp.select();
}

export function closeTopicModal(): void {
  $("topic-modal").classList.remove("open");
  S.topicTarget = "";
}

export function renderModModal(): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || !isChan(buf.name)) return;
  $("mod-modal-title").textContent = `${t("mod.title")} — ${buf.name}`;

  const grid = $("mod-mode-grid");
  grid.textContent = "";
  for (const m of MOD_MODES) {
    const active = buf.modes.has(m.flag);
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "small mod-mode-btn" + (active ? " active" : "");
    btn.textContent = m.label;
    btn.onclick = () => {
      sendRaw(`MODE ${buf.name} ${active ? "-" : "+"}${m.flag}`);
    };
    grid.appendChild(btn);
  }

  const banWrap = $("mod-ban-list");
  banWrap.textContent = "";
  if (buf.bans.length === 0) {
    const empty = document.createElement("div");
    empty.className = "muted";
    empty.textContent = t("mod.bans.empty");
    banWrap.appendChild(empty);
  } else {
    for (const mask of buf.bans) {
      const row = document.createElement("div");
      row.className = "mod-ban-row";
      const code = document.createElement("span");
      code.className = "mono";
      code.textContent = mask;
      const unban = document.createElement("button");
      unban.type = "button";
      unban.className = "small";
      unban.textContent = t("mod.unban");
      unban.onclick = () => {
        sendRaw(`MODE ${buf.name} -b ${mask}`);
        buf.bans = buf.bans.filter((b) => b !== mask);
        renderModModal();
      };
      row.appendChild(code);
      row.appendChild(unban);
      banWrap.appendChild(row);
    }
  }
}

export function openModModal(): void {
  const buf = buffers.get(S.activeBuf);
  if (!buf || !isOperatorInBuffer(buf)) return;
  buf.bans = [];
  sendRaw(`MODE ${buf.name}`);
  sendRaw(`MODE ${buf.name} +b`);
  renderModModal();
  $("mod-modal").classList.add("open");
}

export function closeModModal(): void {
  $("mod-modal").classList.remove("open");
}

export function renderDiscoverList(): void {
  const wrap = $("discover-list");
  wrap.textContent = "";
  if (S.discoverLoading && S.discoverChannels.length === 0) {
    const msg = document.createElement("div");
    msg.className = "muted discover-empty";
    msg.textContent = t("discover.loading");
    wrap.appendChild(msg);
    return;
  }
  const q = $<HTMLInputElement>("inp-discover-filter").value.trim()
    .toLowerCase();
  const filtered = S.discoverChannels
    .filter((c) =>
      !q || c.name.toLowerCase().includes(q) ||
      c.topic.toLowerCase().includes(q)
    )
    .sort((a, b) => b.users - a.users || a.name.localeCompare(b.name));

  if (filtered.length === 0) {
    const msg = document.createElement("div");
    msg.className = "muted discover-empty";
    msg.textContent = t("discover.empty");
    wrap.appendChild(msg);
    return;
  }

  for (const ch of filtered) {
    const row = document.createElement("div");
    row.className = "discover-row";

    const info = document.createElement("div");
    info.className = "discover-info";

    const top = document.createElement("div");
    top.className = "discover-top";
    const nameEl = document.createElement("strong");
    nameEl.dir = "ltr";
    nameEl.textContent = ch.name;
    const countEl = document.createElement("span");
    countEl.className = "discover-count";
    countEl.textContent = t("discover.users", { count: ch.users });
    top.appendChild(nameEl);
    top.appendChild(countEl);

    info.appendChild(top);
    if (ch.topic) {
      const topicEl = document.createElement("div");
      topicEl.className = "discover-topic muted";
      topicEl.dir = "auto";
      topicEl.textContent = ch.topic;
      info.appendChild(topicEl);
    }

    const joined = buffers.has(ircFold(ch.name));
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = joined ? "small" : "small primary";
    btn.textContent = joined ? t("discover.open") : t("btn.join");
    btn.onclick = () => {
      closeDiscoverModal();
      if (joined) {
        switchBuf(ircFold(ch.name));
      } else {
        sendRaw(`JOIN ${ch.name}`);
      }
    };

    row.appendChild(info);
    row.appendChild(btn);
    wrap.appendChild(row);
  }
}

export function requestDiscoverList(): void {
  S.discoverChannels = [];
  S.discoverLoading = true;
  renderDiscoverList();
  sendRaw("LIST");
}

export function openDiscoverModal(): void {
  closeDrawers();
  $("discover-modal").classList.add("open");
  requestDiscoverList();
  $<HTMLInputElement>("inp-discover-filter").focus();
}

export function closeDiscoverModal(): void {
  $("discover-modal").classList.remove("open");
  S.discoverLoading = false;
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-topic").onclick = openTopicModal;

  $("btn-close-topic").onclick = closeTopicModal;

  $("btn-cancel-topic").onclick = closeTopicModal;

  $("topic-modal").addEventListener("click", (ev) => {
    if (ev.target === $("topic-modal")) closeTopicModal();
  });

  $<HTMLFormElement>("topic-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    if (!S.topicTarget) return;
    const next = $<HTMLInputElement>("inp-topic").value.trim();
    sendRaw(`TOPIC ${S.topicTarget} :${next}`);
    closeTopicModal();
  });

  $("btn-conn").onclick = () => {
    if (S.connOffline) {
      S.userClosed = false;
      if (S.lastWsUrl) reconnectNow();
      return;
    }
    S.userClosed = true;
    stopReconnecting();
    clearSession();
    stopHeartbeat();
    if (calls.busy) calls.hangup();
    calls.reset();
    S.isRegistered = false;
    S.hiddenUnread = 0;
    S.hiddenMentions = 0;
    if (S.ws && S.ws.readyState === WebSocket.OPEN) {
      sendRaw("QUIT :Leaving WebIRC");
      S.ws.close();
    }
    S.ws = null;
    updateTitle();
    if (location.pathname !== "/") {
      history.replaceState(null, "", "/");
    }
    $("chat-view").classList.remove("active");
    $("connect-view").style.display = "flex";
  };

  $<HTMLFormElement>("join-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const inp = $<HTMLInputElement>("inp-join");
    const ch = inp.value.trim();
    if (!ch) return;
    sendRaw(`JOIN ${isChan(ch) ? ch : `#${ch}`}`);
    inp.value = "";
  });

  $<HTMLInputElement>("inp-member-filter").addEventListener("input", (ev) => {
    S.memberFilter = (ev.target as HTMLInputElement).value.trim();
    renderMembers();
  });

  $("btn-mod").onclick = openModModal;

  $("btn-close-mod").onclick = closeModModal;

  $("mod-modal").addEventListener("click", (ev) => {
    if (ev.target === $("mod-modal")) closeModModal();
  });

  $<HTMLFormElement>("mod-invite-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const buf = buffers.get(S.activeBuf);
    const inp = $<HTMLInputElement>("inp-mod-invite");
    const targetNick = inp.value.trim();
    if (buf && isChan(buf.name) && targetNick) {
      sendRaw(`INVITE ${targetNick} ${buf.name}`);
      inp.value = "";
    }
  });

  $<HTMLFormElement>("mod-notice-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const buf = buffers.get(S.activeBuf);
    const inp = $<HTMLInputElement>("inp-mod-notice");
    const msg = inp.value.trim();
    if (buf && isChan(buf.name) && msg) {
      sendRaw(`NOTICE ${buf.name} :${msg}`);
      inp.value = "";
    }
  });

  $<HTMLFormElement>("mod-ban-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    const buf = buffers.get(S.activeBuf);
    const inp = $<HTMLInputElement>("inp-mod-ban");
    const mask = inp.value.trim();
    if (buf && isChan(buf.name) && mask) {
      sendRaw(`MODE ${buf.name} +b ${mask}`);
      if (!buf.bans.includes(mask)) buf.bans.push(mask);
      inp.value = "";
      renderModModal();
    }
  });

  $("btn-discover").onclick = openDiscoverModal;

  $("btn-close-discover").onclick = closeDiscoverModal;

  $("btn-discover-refresh").onclick = requestDiscoverList;

  $("inp-discover-filter").addEventListener("input", renderDiscoverList);

  $("discover-modal").addEventListener("click", (ev) => {
    if (ev.target === $("discover-modal")) closeDiscoverModal();
  });

  // Keep chat workspace pinned cleanly above the iOS software keyboard
  if (globalThis.visualViewport) {
    const syncViewport = (): void => {
      const vv = globalThis.visualViewport;
      if (!vv) return;
      const chat = $("chat-view");
      if (!chat.classList.contains("active")) return;
      const msgs = $("messages");
      const wasAtBottom =
        msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight <
          80;
      chat.style.height = `${Math.round(vv.height)}px`;
      globalThis.scrollTo(0, 0);
      if (wasAtBottom) msgs.scrollTop = msgs.scrollHeight;
    };
    globalThis.visualViewport.addEventListener("resize", syncViewport);
    globalThis.visualViewport.addEventListener("scroll", syncViewport);
  }
}
