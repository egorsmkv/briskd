export interface FormatSegment {
  text: string;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  strike?: boolean;
  mono?: boolean;
  fg?: string;
  bg?: string;
}

// Standard mIRC 0..15 palette (tuned for dark/light readability like Halloy)
const MIRC_COLORS: readonly string[] = [
  "#ffffff", // 0 white
  "#111827", // 1 black
  "#2563eb", // 2 blue
  "#16a34a", // 3 green
  "#ef4444", // 4 red
  "#b91c1c", // 5 brown/maroon
  "#9333ea", // 6 purple
  "#ea580c", // 7 orange
  "#eab308", // 8 yellow
  "#22c55e", // 9 light green
  "#0d9488", // 10 teal
  "#06b6d4", // 11 cyan
  "#3b82f6", // 12 light blue
  "#ec4899", // 13 pink
  "#6b7280", // 14 grey
  "#9ca3af", // 15 light grey
];

function mircColor(code: number): string | undefined {
  if (code >= 0 && code < MIRC_COLORS.length) return MIRC_COLORS[code];
  return undefined;
}

// Strip Unicode bidi override/isolate control chars to prevent RLO URL/filename spoofing
// while preserving natural Hebrew/Arabic RTL text.
const BIDI_OVERRIDE_RE = /[\u202a-\u202e\u2066-\u2069]/g;

export function sanitizeDisplayText(input: string): string {
  return input.replace(BIDI_OVERRIDE_RE, "");
}

/**
 * Parse IRC formatting control codes (\x02 bold, \x03 mIRC color, \x04 hex color,
 * \x0F reset, \x11 monospace, \x16 reverse, \x1D italic, \x1E strike, \x1F underline)
 * into styled text segments.
 */
export function parseIrcFormatting(rawInput: string): FormatSegment[] {
  const input = sanitizeDisplayText(rawInput);
  const out: FormatSegment[] = [];
  let bold = false;
  let italic = false;
  let underline = false;
  let strike = false;
  let mono = false;
  let reverse = false;
  let fg: string | undefined;
  let bg: string | undefined;
  let buf = "";

  const flush = () => {
    if (!buf) return;
    const seg: FormatSegment = { text: buf };
    if (bold) seg.bold = true;
    if (italic) seg.italic = true;
    if (underline) seg.underline = true;
    if (strike) seg.strike = true;
    if (mono) seg.mono = true;
    const effFg = reverse ? bg : fg;
    const effBg = reverse ? fg : bg;
    if (effFg) seg.fg = effFg;
    if (effBg) seg.bg = effBg;
    out.push(seg);
    buf = "";
  };

  for (let i = 0; i < input.length; i++) {
    const ch = input.charCodeAt(i);
    if (ch === 0x02) {
      flush();
      bold = !bold;
    } else if (ch === 0x1d) {
      flush();
      italic = !italic;
    } else if (ch === 0x1f) {
      flush();
      underline = !underline;
    } else if (ch === 0x1e) {
      flush();
      strike = !strike;
    } else if (ch === 0x11) {
      flush();
      mono = !mono;
    } else if (ch === 0x16) {
      flush();
      reverse = !reverse;
    } else if (ch === 0x0f) {
      flush();
      bold = false;
      italic = false;
      underline = false;
      strike = false;
      mono = false;
      reverse = false;
      fg = undefined;
      bg = undefined;
    } else if (ch === 0x03) {
      flush();
      const rest = input.slice(i + 1);
      const m = rest.match(/^(\d{1,2})(?:,(\d{1,2}))?/);
      if (m) {
        fg = mircColor(parseInt(m[1], 10));
        if (m[2] !== undefined) bg = mircColor(parseInt(m[2], 10));
        i += m[0].length;
      } else {
        fg = undefined;
        bg = undefined;
      }
    } else if (ch === 0x04) {
      flush();
      const rest = input.slice(i + 1);
      const m = rest.match(/^([0-9a-fA-F]{6})(?:,([0-9a-fA-F]{6}))?/);
      if (m) {
        fg = `#${m[1]}`;
        if (m[2]) bg = `#${m[2]}`;
        i += m[0].length;
      } else {
        fg = undefined;
        bg = undefined;
      }
    } else {
      buf += input[i];
    }
  }
  flush();
  return out;
}

export interface RenderMessageOptions {
  myNick?: string;
  onChannelClick?: (channel: string) => void;
}

const TOKEN_RE =
  /(https?:\/\/[^\s<>()]+(?:\([^\s<>()]*\)[^\s<>()]*)*)|(`[^`\n]{1,120}`)|((?:^|(?<=[\s(\[{,]))#[a-zA-Z0-9_\-.+]{1,50})/g;

function trimUrlTrailing(raw: string): { url: string; tail: string } {
  let url = raw;
  let tail = "";
  while (url.length > 0 && /[.,!?;:'"]$/.test(url)) {
    tail = url[url.length - 1] + tail;
    url = url.slice(0, -1);
  }
  return { url, tail };
}

function appendTextWithMentions(
  parent: Node,
  text: string,
  myNick?: string,
): void {
  if (!myNick) {
    parent.appendChild(document.createTextNode(text));
    return;
  }
  const escaped = myNick.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`(^|\\W)(${escaped})(?=\\W|$)`, "gi");
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const lead = m[1];
    const hit = m[2];
    const start = m.index + lead.length;
    if (start > last) {
      parent.appendChild(document.createTextNode(text.slice(last, start)));
    }
    const span = document.createElement("span");
    span.className = "irc-mention";
    span.textContent = hit;
    parent.appendChild(span);
    last = start + hit.length;
  }
  if (last < text.length) {
    parent.appendChild(document.createTextNode(text.slice(last)));
  }
}

function safeHttpUrl(raw: string): string | null {
  try {
    const u = new URL(raw);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    return u.href;
  } catch {
    return null;
  }
}

function appendRichText(
  parent: Node,
  text: string,
  opts: RenderMessageOptions,
): void {
  TOKEN_RE.lastIndex = 0;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = TOKEN_RE.exec(text)) !== null) {
    if (m.index > last) {
      appendTextWithMentions(parent, text.slice(last, m.index), opts.myNick);
    }
    if (m[1]) {
      const { url, tail } = trimUrlTrailing(m[1]);
      const href = safeHttpUrl(url);
      if (href) {
        const a = document.createElement("a");
        a.className = "irc-link";
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.dir = "ltr";
        a.textContent = url;
        parent.appendChild(a);
      } else {
        parent.appendChild(document.createTextNode(url));
      }
      if (tail) parent.appendChild(document.createTextNode(tail));
    } else if (m[2]) {
      const code = document.createElement("code");
      code.className = "irc-code";
      code.dir = "ltr";
      code.textContent = m[2].slice(1, -1);
      parent.appendChild(code);
    } else if (m[3]) {
      const chan = m[3];
      const span = document.createElement("span");
      span.className = "irc-chan";
      span.dir = "ltr";
      span.textContent = chan;
      span.title = `Join ${chan}`;
      if (opts.onChannelClick) {
        const handler = opts.onChannelClick;
        span.onclick = () => handler(chan);
      }
      parent.appendChild(span);
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) {
    appendTextWithMentions(parent, text.slice(last), opts.myNick);
  }
}

/**
 * Render an IRC message string into a safe DOM DocumentFragment with Halloy-style
 * IRC formatting (bold/italic/underline/strike/mono/colors), clickable URLs,
 * clickable #channels, inline `code`, and nick mention highlights.
 */
export function renderIrcMessage(
  raw: string,
  opts: RenderMessageOptions = {},
): DocumentFragment {
  const frag = document.createDocumentFragment();
  const segments = parseIrcFormatting(raw);
  for (const seg of segments) {
    const hasStyle = seg.bold || seg.italic || seg.underline || seg.strike ||
      seg.mono || seg.fg || seg.bg;
    if (!hasStyle) {
      appendRichText(frag, seg.text, opts);
      continue;
    }
    const span = document.createElement("span");
    const classes: string[] = [];
    if (seg.bold) classes.push("irc-bold");
    if (seg.italic) classes.push("irc-italic");
    if (seg.underline) classes.push("irc-underline");
    if (seg.strike) classes.push("irc-strike");
    if (seg.mono) classes.push("irc-mono");
    if (classes.length) span.className = classes.join(" ");
    if (seg.fg) span.style.color = seg.fg;
    if (seg.bg) span.style.backgroundColor = seg.bg;
    appendRichText(span, seg.text, opts);
    frag.appendChild(span);
  }
  return frag;
}

export function formatDayLabel(epochMs: number): string {
  const d = new Date(epochMs);
  const now = new Date();
  const sameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate();
  if (sameDay(d, now)) return "Today";
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (sameDay(d, yesterday)) return "Yesterday";
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

export function dayKey(epochMs: number): string {
  const d = new Date(epochMs);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}
