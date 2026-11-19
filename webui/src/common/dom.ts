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
      data = { error: text };
    }
  }
  return { ok: res.ok, status: res.status, data: data as T };
}
