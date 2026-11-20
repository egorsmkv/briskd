// Admin HTTP API: payload types of GET /api/overview and GET /api/media, and
// POST /api/action. HTTP Basic credentials are the browser's cached ones.
import { type JsonResult, postJson } from "../../../common/dom.ts";

export interface ListenerInfo {
  transport: string;
  port: number;
}

export interface StatusData {
  status?: string;
  name?: string;
  network?: string;
  uptime_seconds?: number;
  listeners?: ListenerInfo[];
  sessions?: number;
  max_clients?: number;
  registered_users?: number;
  operators_online?: number;
  channels?: number;
  remote_channels?: number;
  known_servers?: number;
  remote_users?: number;
  services?: number;
  accounts?: number;
  retention?: string;
  db_disk_bytes?: number;
  db_memory_bytes?: number;
  db_tables?: number;
  memory_bytes?: number;
  erlang_processes?: number;
  log_level?: string;
}

export interface ClientEntry {
  nick?: string;
  user?: string;
  host?: string;
  account?: string | null;
  operator?: boolean;
  secure?: boolean;
  channels?: number | string[];
  idle_seconds?: number;
}

export interface ChannelEntry {
  name: string;
  local_members?: number;
  remote_members?: number;
  modes?: string;
  predefined?: boolean;
  topic?: string;
}

export interface ConnectedLink {
  name?: string;
  server?: string;
  hop?: number;
  info?: string;
}

export interface ConfiguredLink {
  name: string;
  host: string;
  port: number;
  tls?: boolean;
}

export interface AccountEntry {
  name: string;
  verified?: boolean;
  email?: string | null;
  certfps?: number;
}

export interface DroneblBan {
  ip: string;
  code: number;
  expires_in?: number;
  reason?: string;
}

export interface MediaObject {
  id: string;
  size: number;
  last_modified?: string;
  preview?: boolean;
}

export type Features = Record<string, boolean>;

export interface MediaPayload {
  features?: Features;
  voice?: {
    enabled: boolean;
    bucket?: string;
    max_bytes?: number;
    max_duration?: number;
    objects?: MediaObject[];
    error?: string;
  };
  files?: {
    enabled: boolean;
    bucket?: string;
    max_bytes?: number;
    objects?: MediaObject[];
    error?: string;
  };
}

export interface OverviewPayload {
  status?: StatusData;
  clients?: { clients?: ClientEntry[] };
  channels?: { channels?: ChannelEntry[] };
  links?: { connected?: ConnectedLink[]; configured?: ConfiguredLink[] };
  accounts?: { accounts?: AccountEntry[] };
  dronebl?: {
    stats?: {
      enabled?: boolean;
      bans?: number;
      cached_clean?: number;
      in_flight?: number;
    };
    bans?: DroneblBan[];
  };
  features?: Features;
  media_summary?: {
    voice_enabled?: boolean;
    voice_max_bytes?: number;
    voice_max_duration?: number;
    files_enabled?: boolean;
    files_max_bytes?: number;
  };
}

/** GET a JSON document as text (uncached); throws "HTTP <status>". */
async function getText(url: string): Promise<string> {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return await res.text();
}

/** The raw text of GET /api/overview. */
export function fetchOverviewText(): Promise<string> {
  return getText("/api/overview");
}

/** The raw text of GET /api/media. */
export function fetchMediaText(): Promise<string> {
  return getText("/api/media");
}

export type ActionReply = Record<string, unknown>;

/** POST /api/action with `{action, args}`. */
export function postAction(
  action: string,
  args: string[],
): Promise<JsonResult<ActionReply>> {
  return postJson<ActionReply>("/api/action", { action, args });
}
