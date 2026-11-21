// The slash-command list of the message box: typing "/" at the start lists
// the commands that apply here, filtered as the name is typed; Up/Down move,
// Enter or Tab insert "/command ", Escape closes, and a click picks. While
// the arguments of a known command are typed, a one-line hint shows its
// syntax. The rules (what counts as a command, ranking, insertion) are in
// slash.ts; the mention list (mention_picker.ts) works the same way.
import { byId as $ } from "../common/dom.ts";
import { t } from "../common/i18n.ts";
import { calls } from "./calls_ui.ts";
import { msgInp } from "./composer.ts";
import { e2ee } from "./e2ee_ui.ts";
import {
  applyCommand,
  type CommandSpec,
  rankCommands,
  slashState,
} from "./slash.ts";
import { buffers, S } from "./state.ts";
import { capOn } from "./caps.ts";
import { SEARCH_CAP } from "./search.ts";
import { isChan } from "./util.ts";

let items: CommandSpec[] = [];
let active = 0;
/** "list" while choosing a command, "hint" while typing its arguments. */
let mode: "closed" | "list" | "hint" = "closed";

function picker(): HTMLElement {
  return $("command-picker");
}

/** Whether the command list (not the hint) takes the keyboard. */
export function isCommandPickerOpen(): boolean {
  return mode === "list";
}

/** Whether a command applies in the open conversation. */
function available(spec: CommandSpec): boolean {
  switch (spec.needs) {
    case "channel":
      return isChan(buffers.get(S.activeBuf)?.name ?? "");
    case "calls":
      return calls.enabled;
    case "e2ee":
      return e2ee.isServerSupported();
    case "oper":
      return S.isIrcOp;
    case "search":
      return S.isRegistered && capOn(SEARCH_CAP);
    default:
      return true;
  }
}

function close(): void {
  if (mode === "closed") return;
  mode = "closed";
  items = [];
  picker().classList.add("hidden");
  picker().textContent = "";
  msgInp.setAttribute("aria-expanded", "false");
  msgInp.removeAttribute("aria-activedescendant");
}

/** A row: "/name", its arguments, and what it does. */
function row(spec: CommandSpec, id?: string): HTMLElement {
  const opt = document.createElement("div");
  opt.className = "cmd-opt";
  if (id) opt.id = id;
  const head = document.createElement("span");
  head.className = "cmd-head";
  head.dir = "ltr";
  const name = document.createElement("span");
  name.className = "cmd-name";
  name.textContent = `/${spec.name}`;
  head.appendChild(name);
  if (spec.args) {
    const args = document.createElement("span");
    args.className = "cmd-args";
    args.textContent = spec.args;
    head.appendChild(args);
  }
  const desc = document.createElement("span");
  desc.className = "cmd-desc";
  desc.textContent = t(spec.desc);
  opt.append(head, desc);
  return opt;
}

function renderList(): void {
  const list = picker();
  list.textContent = "";
  list.setAttribute("role", "listbox");
  list.classList.remove("hint");
  items.forEach((spec, i) => {
    const opt = row(spec, `cmd-opt-${i}`);
    opt.classList.toggle("active", i === active);
    opt.setAttribute("role", "option");
    opt.setAttribute("aria-selected", String(i === active));
    // Keep focus in the message box: pick on mousedown, not after blur.
    opt.addEventListener("mousedown", (ev) => {
      ev.preventDefault();
      choose(i);
    });
    list.appendChild(opt);
  });
  list.classList.remove("hidden");
  msgInp.setAttribute("aria-controls", "command-picker");
  msgInp.setAttribute("aria-expanded", "true");
  msgInp.setAttribute("aria-activedescendant", `cmd-opt-${active}`);
  list.querySelector(".cmd-opt.active")?.scrollIntoView({ block: "nearest" });
}

function renderHint(spec: CommandSpec): void {
  const list = picker();
  list.textContent = "";
  list.removeAttribute("role");
  list.classList.add("hint");
  list.appendChild(row(spec));
  list.classList.remove("hidden");
  msgInp.setAttribute("aria-expanded", "false");
  msgInp.removeAttribute("aria-activedescendant");
}

/** Re-read the text at the caret and show, update, or close the list. */
export function updateCommandPicker(): void {
  const caret = msgInp.selectionStart ?? 0;
  if (caret !== msgInp.selectionEnd) return close();
  const state = slashState(msgInp.value, caret);
  if (!state) return close();
  if (state.kind === "args") {
    mode = "hint";
    items = [];
    renderHint(state.spec);
    return;
  }
  const ranked = rankCommands(state.query, available);
  if (ranked.length === 0) return close();
  const keep = mode === "list" ? items[active] : undefined;
  mode = "list";
  items = ranked;
  active = keep ? Math.max(0, ranked.indexOf(keep)) : 0;
  renderList();
}

function choose(index: number): void {
  const spec = items[index];
  if (!spec) return;
  const next = applyCommand(msgInp.value, spec);
  msgInp.value = next.text;
  msgInp.setSelectionRange(next.caret, next.caret);
  // Let the composer resize; the list turns into the argument hint.
  msgInp.dispatchEvent(new Event("input", { bubbles: true }));
}

/**
 * Keys for the open list; the message box calls this first and skips its
 * own handling (send, history, Tab completion) when it returns true. Enter
 * on a command without arguments that is already typed in full sends it.
 */
export function handleCommandKey(ev: KeyboardEvent): boolean {
  if (mode !== "list" || ev.isComposing) return false;
  switch (ev.key) {
    case "ArrowDown":
    case "ArrowUp": {
      const step = ev.key === "ArrowDown" ? 1 : -1;
      active = (active + step + items.length) % items.length;
      renderList();
      break;
    }
    case "Enter":
    case "Tab": {
      if (ev.shiftKey) return false;
      const spec = items[active];
      const typed = msgInp.value.trim().slice(1).toLowerCase();
      if (ev.key === "Enter" && spec && !spec.args && typed === spec.name) {
        close();
        return false;
      }
      choose(active);
      break;
    }
    case "Escape":
      close();
      ev.stopPropagation();
      break;
    default:
      return false;
  }
  ev.preventDefault();
  return true;
}

/** Wire the list to the message box. */
export function init(): void {
  picker().setAttribute("aria-label", t("cmd.picker"));
  msgInp.addEventListener("input", updateCommandPicker);
  msgInp.addEventListener("click", updateCommandPicker);
  msgInp.addEventListener("keyup", (ev) => {
    if (
      ev.key === "ArrowLeft" || ev.key === "ArrowRight" ||
      ev.key === "Home" || ev.key === "End"
    ) {
      updateCommandPicker();
    }
  });
  msgInp.addEventListener("blur", close);
}
