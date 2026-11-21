// The message search dialog (egorsmkv.github.io/search; protocol helpers in
// search.ts). The header button and Ctrl+K (Cmd+K) open it when the server
// offers search; /search <words> opens it with a query. Results are drawn
// with text nodes only: message text is untrusted. Choosing a result opens
// its conversation and scrolls to the message, asking the server for the
// history around it first when that part is not loaded.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { ircFold } from "../common/ircv3.ts";
import { ensureBuf } from "./buffers.ts";
import { capOn } from "./caps.ts";
import { jumpToMessage } from "./chat/scroll.ts";
import { sendRaw } from "./connection.ts";
import {
  highlight,
  queryTerms,
  SEARCH_CAP,
  SearchCollector,
  searchCommand,
  type SearchFeed,
  type SearchHit,
} from "./search.ts";
import { closeDrawers, renderBuffers, switchBuf } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { isChan } from "./util.ts";
import type { IrcMessage } from "./types.ts";

/** Results asked for at a time. */
const PAGE = 30;
/** How long to wait for history around a result before giving up, ms. */
const JUMP_WAIT_MS = 4000;

const collector = new SearchCollector(() => S.myNick, ircFold);

let pending = false;
let query = "";
let target = "*";
let hits: SearchHit[] = [];
let total = 0;

function enabled(): boolean {
  return S.isRegistered && capOn(SEARCH_CAP);
}

/** The header button: shown while the server offers search. */
export function updateSearchButton(): void {
  $("btn-search").classList.toggle("hidden", !enabled());
}

/** The conversation the dialog searches when "This conversation" is chosen. */
function hereTarget(): string | null {
  const buf = buffers.get(S.activeBuf);
  return buf && buf.name !== "*status" ? buf.name : null;
}

export function openSearch(initial = ""): void {
  if (!enabled()) return;
  closeDrawers();
  const here = hereTarget();
  const opt = $<HTMLOptionElement>("opt-search-here");
  opt.disabled = here === null;
  opt.textContent = here
    ? t("search.scope.here", { name: here })
    : t("search.scope.none");
  const scope = $<HTMLSelectElement>("sel-search-scope");
  if (here === null) scope.value = "all";
  $("search-modal").classList.add("open");
  const input = $<HTMLInputElement>("inp-search");
  if (initial) {
    input.value = initial;
    run();
  }
  input.focus();
  input.select();
}

export function closeSearch(): void {
  $("search-modal").classList.remove("open");
}

function isOpen(): boolean {
  return $("search-modal").classList.contains("open");
}

function run(): void {
  const q = $<HTMLInputElement>("inp-search").value.trim();
  if (!q || pending) return;
  const here = hereTarget();
  target = $<HTMLSelectElement>("sel-search-scope").value === "here" && here
    ? here
    : "*";
  query = q;
  hits = [];
  total = 0;
  request();
}

function request(before?: number): void {
  pending = true;
  setStatus(t("search.searching"));
  $("btn-search-more").classList.add("hidden");
  sendRaw(searchCommand(target, PAGE, query, before));
}

function loadMore(): void {
  if (pending || hits.length === 0) return;
  request(hits[hits.length - 1].time);
}

function setStatus(text: string, error = false): void {
  const el = $("search-status");
  el.textContent = text;
  el.classList.toggle("err", error);
}

/**
 * Feed an incoming line (after multiline batches are assembled). Returns
 * true when it was a search reply.
 */
export function handleSearchReply(msg: IrcMessage): boolean {
  const fed: SearchFeed = collector.feed(msg);
  switch (fed.kind) {
    case "pass":
      return false;
    case "consumed":
      return true;
    case "done":
      pending = false;
      hits = hits.concat(fed.result.hits);
      if (total === 0) total = fed.result.total;
      render();
      return true;
    case "fail":
      pending = false;
      setStatus(failText(fed.code, fed.target), true);
      return true;
  }
}

function failText(code: string, where: string): string {
  switch (code) {
    case "INVALID_TARGET":
      return t("search.err.target", { name: where });
    case "TEMPORARILY_UNAVAILABLE":
      return t("search.err.unavailable");
    case "INVALID_PARAMS":
      return t("search.err.query");
    default:
      return t("search.err.other", { code });
  }
}

function render(): void {
  const list = $("search-results");
  list.textContent = "";
  setStatus(
    hits.length === 0
      ? t("search.none")
      : t("search.count", { shown: hits.length, total }),
  );
  const terms = queryTerms(query);
  for (const hit of hits) list.appendChild(row(hit, terms));
  $("btn-search-more").classList.toggle("hidden", hits.length >= total);
}

function row(hit: SearchHit, terms: string[]): HTMLLIElement {
  const li = document.createElement("li");
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "search-hit";
  btn.onclick = () => open(hit);

  const head = document.createElement("span");
  head.className = "search-hit-head";
  const where = document.createElement("strong");
  where.dir = "ltr";
  where.textContent = isChan(hit.conversation)
    ? hit.conversation
    : `@${hit.conversation}`;
  const who = document.createElement("span");
  who.className = "search-hit-nick";
  who.dir = "auto";
  who.textContent = hit.nick;
  const when = document.createElement("time");
  when.className = "search-hit-time muted";
  if (hit.time) {
    const d = new Date(hit.time);
    when.dateTime = d.toISOString();
    when.textContent = d.toLocaleString(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    });
  }
  head.append(where, who, when);

  const body = document.createElement("span");
  body.className = "search-hit-text";
  body.dir = "auto";
  for (const part of highlight(hit.text, terms)) {
    if (part.match) {
      const mark = document.createElement("mark");
      mark.textContent = part.text;
      body.appendChild(mark);
    } else {
      body.appendChild(document.createTextNode(part.text));
    }
  }
  btn.append(head, body);
  li.appendChild(btn);
  return li;
}

/** Open a result's conversation and scroll to it. */
function open(hit: SearchHit): void {
  closeSearch();
  const key = ircFold(hit.conversation);
  if (!buffers.has(key)) {
    ensureBuf(hit.conversation);
    renderBuffers();
  }
  switchBuf(key);
  const msgid = hit.msgid;
  if (!msgid) return;
  const loaded = () =>
    buffers.get(key)?.lines.some((l) => l.msgid === msgid) ?? false;
  if (loaded()) {
    jumpToMessage(msgid);
    return;
  }
  if (!capOn("draft/chathistory")) return;
  sendRaw(`CHATHISTORY AROUND ${hit.conversation} msgid=${msgid} 50`);
  const until = Date.now() + JUMP_WAIT_MS;
  const wait = () => {
    if (S.activeBuf !== key) return; // the user went elsewhere
    if (loaded()) jumpToMessage(msgid);
    else if (Date.now() < until) setTimeout(wait, 100);
  };
  setTimeout(wait, 100);
}

/** The connection was lost: drop half-received replies. */
export function resetSearch(): void {
  collector.clear();
  pending = false;
  updateSearchButton();
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  $("btn-search").onclick = () => openSearch();
  $("btn-close-search").onclick = closeSearch;
  $("btn-search-more").onclick = loadMore;
  $("search-modal").addEventListener("click", (ev) => {
    if (ev.target === $("search-modal")) closeSearch();
  });
  $<HTMLFormElement>("search-form").addEventListener("submit", (ev) => {
    ev.preventDefault();
    run();
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && isOpen()) {
      ev.preventDefault();
      closeSearch();
    } else if (
      (ev.ctrlKey || ev.metaKey) && !ev.altKey && !ev.shiftKey &&
      ev.key.toLowerCase() === "k" && enabled()
    ) {
      ev.preventDefault();
      openSearch();
    }
  });
  updateSearchButton();
}
