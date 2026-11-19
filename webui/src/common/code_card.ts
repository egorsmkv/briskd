/**
 * Zero-dependency collapsible syntax-highlighted code snippet / paste card.
 *
 * Uses pure DOM APIs (no innerHTML), respects strict CSP, renders always LTR
 * for readability even in Hebrew RTL mode, and supports one-click copy.
 */

import { sanitizeDisplayName } from "./file_card.ts";

export type TokenKind = "plain" | "kw" | "str" | "num" | "cmt";

export interface CodeToken {
  kind: TokenKind;
  text: string;
}

const KEYWORDS = new Set([
  // Common across JS/TS/Rust/Go/Python/Erlang/SQL/Bash
  "async",
  "await",
  "break",
  "case",
  "catch",
  "class",
  "const",
  "continue",
  "def",
  "default",
  "do",
  "else",
  "end",
  "enum",
  "export",
  "false",
  "finally",
  "fn",
  "for",
  "from",
  "fun",
  "func",
  "function",
  "if",
  "impl",
  "import",
  "in",
  "interface",
  "let",
  "match",
  "mod",
  "module",
  "new",
  "nil",
  "null",
  "of",
  "or",
  "package",
  "private",
  "pub",
  "public",
  "receive",
  "return",
  "select",
  "self",
  "spawn",
  "struct",
  "switch",
  "throw",
  "trait",
  "true",
  "try",
  "type",
  "undefined",
  "use",
  "var",
  "when",
  "where",
  "while",
  "yield",
  "SELECT",
  "FROM",
  "WHERE",
  "INSERT",
  "UPDATE",
  "DELETE",
  "JOIN",
  "LIMIT",
]);

const HASH_COMMENT_LANGS = new Set(["python", "bash", "sh", "yaml", "toml"]);
const PCT_COMMENT_LANGS = new Set(["erlang", "erl"]);
const DASH_COMMENT_LANGS = new Set(["sql"]);

/** Lightweight single-line syntax tokenizer producing typed spans. */
export function tokenizeCodeLine(line: string, lang: string): CodeToken[] {
  const l = (lang || "text").toLowerCase();
  if (l === "text" || l === "plain") {
    return line ? [{ kind: "plain", text: line }] : [];
  }
  const tokens: CodeToken[] = [];
  let i = 0;
  const n = line.length;

  const push = (kind: TokenKind, text: string): void => {
    if (!text) return;
    const prev = tokens[tokens.length - 1];
    if (prev && prev.kind === kind) prev.text += text;
    else tokens.push({ kind, text });
  };

  while (i < n) {
    const ch = line[i];
    const next = i + 1 < n ? line[i + 1] : "";

    // Line comments
    if (
      (ch === "/" && next === "/") ||
      (ch === "#" && HASH_COMMENT_LANGS.has(l)) ||
      (ch === "%" && PCT_COMMENT_LANGS.has(l)) ||
      (ch === "-" && next === "-" && DASH_COMMENT_LANGS.has(l))
    ) {
      push("cmt", line.slice(i));
      break;
    }

    // Quoted strings
    if (ch === '"' || ch === "'" || ch === "`") {
      let j = i + 1;
      while (j < n) {
        if (line[j] === "\\" && j + 1 < n) {
          j += 2;
          continue;
        }
        if (line[j] === ch) {
          j++;
          break;
        }
        j++;
      }
      push("str", line.slice(i, j));
      i = j;
      continue;
    }

    // Numbers
    if (ch >= "0" && ch <= "9") {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxX._]/.test(line[j])) j++;
      push("num", line.slice(i, j));
      i = j;
      continue;
    }

    // Identifiers / keywords
    if (/[A-Za-z_]/.test(ch)) {
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_-]/.test(line[j])) j++;
      const word = line.slice(i, j);
      push(KEYWORDS.has(word) ? "kw" : "plain", word);
      i = j;
      continue;
    }

    push("plain", ch);
    i++;
  }

  return tokens;
}

const pasteTextCache = new Map<string, string>();
const COLLAPSE_LINES = 14;

export interface CodeCardOptions {
  code: string;
  lang?: string;
  title?: string;
  encrypted?: boolean;
}

export function createCodeCard(opts: CodeCardOptions): HTMLElement {
  const lang = (opts.lang || "text").toLowerCase().replace(/[^a-z0-9_-]/g, "")
    .slice(0, 16) || "text";
  const title = opts.title ? sanitizeDisplayName(opts.title) : "";
  const lines = opts.code.replace(/\r\n/g, "\n").split("\n");
  const collapsible = lines.length > COLLAPSE_LINES;
  let collapsed = collapsible;

  const card = document.createElement("div");
  card.className = "code-card";
  card.dir = "ltr";

  const head = document.createElement("div");
  head.className = "code-head";

  const left = document.createElement("div");
  left.className = "code-head-left";

  const langPill = document.createElement("span");
  langPill.className = "code-lang";
  langPill.textContent = opts.encrypted
    ? `🔒 ${lang.toUpperCase()}`
    : lang.toUpperCase();
  left.appendChild(langPill);

  if (title) {
    const tEl = document.createElement("span");
    tEl.className = "code-title";
    tEl.textContent = title;
    tEl.title = title;
    left.appendChild(tEl);
  }

  const linesEl = document.createElement("span");
  linesEl.className = "code-lines-count";
  linesEl.textContent = `${lines.length}L`;
  left.appendChild(linesEl);

  const right = document.createElement("div");
  right.className = "code-head-right";

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "code-btn";
  copyBtn.textContent = "Copy";
  copyBtn.onclick = () => {
    void navigator.clipboard?.writeText(opts.code).then(() => {
      copyBtn.textContent = "Copied!";
      globalThis.setTimeout(() => {
        copyBtn.textContent = "Copy";
      }, 1500);
    }).catch(() => {});
  };

  if (collapsible) {
    const toggleBtn = document.createElement("button");
    toggleBtn.type = "button";
    toggleBtn.className = "code-btn";
    toggleBtn.textContent = `Expand (${lines.length})`;
    toggleBtn.onclick = () => {
      collapsed = !collapsed;
      pre.classList.toggle("collapsed", collapsed);
      toggleBtn.textContent = collapsed
        ? `Expand (${lines.length})`
        : "Collapse";
    };
    right.appendChild(toggleBtn);
  }
  right.appendChild(copyBtn);

  head.appendChild(left);
  head.appendChild(right);
  card.appendChild(head);

  const pre = document.createElement("pre");
  pre.className = collapsible ? "code-body collapsed" : "code-body";
  const codeEl = document.createElement("code");

  lines.forEach((line, idx) => {
    const row = document.createElement("span");
    row.className = "code-line";
    const num = document.createElement("span");
    num.className = "code-ln";
    num.textContent = String(idx + 1);
    row.appendChild(num);

    const content = document.createElement("span");
    content.className = "code-src";
    const toks = tokenizeCodeLine(line, lang);
    if (toks.length === 0) {
      content.textContent = " ";
    } else {
      for (const tok of toks) {
        if (tok.kind === "plain") {
          content.appendChild(document.createTextNode(tok.text));
        } else {
          const sp = document.createElement("span");
          sp.className = `tok-${tok.kind}`;
          sp.textContent = tok.text;
          content.appendChild(sp);
        }
      }
    }
    row.appendChild(content);
    codeEl.appendChild(row);
  });

  pre.appendChild(codeEl);
  card.appendChild(pre);
  return card;
}

export function createRemoteCodeCard(opts: {
  fileId: string;
  lang?: string;
  title?: string;
}): HTMLElement {
  const cached = pasteTextCache.get(opts.fileId);
  if (cached !== undefined) {
    return createCodeCard({
      code: cached,
      lang: opts.lang,
      title: opts.title,
    });
  }
  const host = document.createElement("div");
  host.className = "e2ee-att-host";
  const loading = document.createElement("span");
  loading.className = "e2ee-att-status";
  loading.textContent = "Loading code snippet...";
  host.appendChild(loading);

  void fetch(`/api/files/${opts.fileId}`).then(async (resp) => {
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const text = (await resp.text()).slice(0, 65536);
    if (pasteTextCache.size > 60) {
      const first = pasteTextCache.keys().next().value;
      if (first) pasteTextCache.delete(first);
    }
    pasteTextCache.set(opts.fileId, text);
    host.textContent = "";
    host.appendChild(
      createCodeCard({
        code: text,
        lang: opts.lang,
        title: opts.title,
      }),
    );
  }).catch(() => {
    loading.textContent = "Failed to load code snippet";
  });

  return host;
}
