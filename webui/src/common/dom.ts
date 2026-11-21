export function byId<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing required DOM element: #${id}`);
  return el as T;
}

export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export function showNotice(id: string, ok: boolean, text: string): void {
  const node = byId(id);
  node.className = ok ? "ok" : "err";
  node.textContent = text;
}

export interface JsonResult<T> {
  ok: boolean;
  status: number;
  data: T;
}

export async function postJson<T>(
  url: string,
  payload: unknown,
): Promise<JsonResult<T>> {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Requested-With": "ircd-webui",
    },
    body: JSON.stringify(payload),
  });
  let data: unknown = {};
  const text = await res.text();
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      // Not JSON (a proxy's error page): report the status, not the page.
      data = { error: `HTTP ${res.status}` };
    }
  }
  // Callers read fields of the reply: anything but an object (null, a
  // number, an array) becomes an empty one, so `data.message` cannot throw.
  if (!data || typeof data !== "object" || Array.isArray(data)) data = {};
  return { ok: res.ok, status: res.status, data: data as T };
}
