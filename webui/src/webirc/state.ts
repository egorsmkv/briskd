// Mutable WebIRC session state shared by the modules (`S`), and the shared collections.
import { type CallAudioSettings, loadCallSettings } from "../call_settings.ts";
import { type MultilineLimits } from "../common/multiline.ts";
import { DOM_WINDOW } from "./chat/policy.ts";
import {
  type BufferState,
  type ComposeMode,
  type DiscoveredChannel,
} from "./types.ts";

/** Mutable session state; modules read and assign `S.field`. */
export const S = {
  callSettings: loadCallSettings() as CallAudioSettings,
  ws: null as WebSocket | null,
  lastWsUrl: "",
  myNick: "",
  saslUser: "",
  saslPass: "",
  autoChannels: [] as string[],
  activeBuf: "*status",
  memberFilter: "",
  advertisedCaps: [] as string[],
  isRegistered: false,
  isIrcOp: false,
  hiddenUnread: 0,
  hiddenMentions: 0,
  /** draft/multiline limits from CAP LS; null when not offered. */
  multilineLimits: null as MultilineLimits | null,
  /** /meta replies (761/766) are echoed to *status until this time. */
  metaEchoUntil: 0,
  userRenderTimer: null as number | null,
  userRenderMessages: false,
  markReadTimer: null as number | null,
  histPos: -1,
  callTicker: null as number | null,
  callNotification: null as Notification | null,
  micTest: null as {
    stream: MediaStream;
    ctx: AudioContext;
    frame: number;
  } | null,
  micTestGen: 0,
  micTestStarting: false,
  speakerTest: null as { audio: HTMLAudioElement; url: string } | null,
  /** Rows allowed in the DOM for the open conversation. */
  renderWindow: DOM_WINDOW,
  /** `.msg` rows currently in #messages. */
  domLines: 0,
  heartbeatTimer: null as number | null,
  heartbeatPending: 0,
  connOffline: false,
  reconnectTimer: null as number | null,
  reconnectTicker: null as number | null,
  reconnectAt: 0,
  reconnectAttempt: 0,
  /** Between an unexpected close and the next successful registration. */
  reconnecting: false,
  /** The user ended the session; do not reconnect. */
  userClosed: false,
  connectTimer: null as number | null,
  stableTimer: null as number | null,
  /** The nickname the user chose; a fallback is used while it is held. */
  preferredNick: "",
  nickAttempt: 0,
  /** NICKLEN from the last 005 (RFC 1459 default 9); survives reconnects. */
  nickLen: 9,
  /** Our NICK to retake the preferred nickname is in flight. */
  regainPending: false,
  desiredBuf: "",
  topicTarget: "",
  composeMode: null as ComposeMode,
  lastTypingSentAt: 0,
  lastTypingTarget: "",
  localTypingStopTimer: null as number | null,
  voiceSupported: false,
  voiceRecorder: null as MediaRecorder | null,
  voiceStream: null as MediaStream | null,
  voiceChunks: [] as Blob[],
  voiceStartMs: 0,
  voiceTimerId: null as number | null,
  voiceCancelled: false,
  voiceTarget: "",
  filesSupported: false,
  filesMaxBytes: 10485760,
  discoverChannels: [] as DiscoveredChannel[],
  discoverLoading: false,
  edgeStartX: 0,
  edgeStartY: 0,
  edgeActive: false,
};

export const buffers = new Map<string, BufferState>();
