// Data types shared across WebIRC modules.
export interface WebircSettings {
  layout: "auto" | "mobile" | "desktop";
  density: "comfortable" | "compact";
  fontSize: "small" | "normal" | "large";
  timestamps: boolean;
  joinPart: boolean;
  notifyMentions: boolean;
  reactions: boolean;
  replies: boolean;
  typing: boolean;
  editing: boolean;
  redaction: boolean;
  linkPreviews: boolean;
  remoteAvatars: boolean;
}

export type FeatureKey =
  | "reactions"
  | "replies"
  | "typing"
  | "editing"
  | "redaction"
  | "link_previews";

export interface IrcMessage {
  tags: Record<string, string>;
  prefix: string;
  nick: string;
  command: string;
  params: string[];
}

export interface ChatLine {
  time: string;
  epochMs: number;
  nick: string;
  text: string;
  kind: "" | "sys" | "err" | "action" | "notice";
  mention?: boolean;
  encrypted?: boolean;
  msgid?: string;
  account?: string;
  replyTo?: string;
  edited?: boolean;
  redacted?: boolean;
  reactions?: Map<string, Set<string>>;
  voiceId?: string;
  voiceDur?: number;
  fileId?: string;
  fileName?: string;
  fileSize?: number;
  albumIds?: string[];
  pasteId?: string;
  pasteLang?: string;
  pasteTitle?: string;
  bot?: boolean;
}

export interface BufferState {
  name: string;
  topic: string;
  lines: ChatLine[];
  unread: number;
  mentions: number;
  members: Map<string, string>;
  modes: Set<string>;
  bans: string[];
}

export interface SavedSession {
  nick: string;
  acct: string;
  pass: string;
  channels: string[];
  wsUrl: string;
  activeBuf: string;
}

// IRCv3 state for the current connection: negotiated capabilities, RPL_ISUPPORT
// tokens, and what extended-join, away-notify, account-notify, chghost,
// setname, WHOX, MONITOR, and draft/metadata-2 tell us about other users.
export interface UserInfo {
  account?: string;
  realname?: string;
  userhost?: string;
  /** Away message ("" when away without one); undefined when present. */
  away?: string;
  bot?: boolean;
  /** MONITOR presence; undefined when the nick is not monitored. */
  online?: boolean;
  meta: Map<string, string>;
}

export type ComposeMode =
  | { kind: "reply"; msgid: string; nick: string; snippet: string }
  | { kind: "edit"; msgid: string; origText: string }
  | null;

// Channel Discovery Modal (LIST / 322 / 323)
export interface DiscoveredChannel {
  name: string;
  users: number;
  topic: string;
}
