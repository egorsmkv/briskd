// The page for each URL path (pure, unit-tested).

export type PageName =
  | "webirc"
  | "signup"
  | "verify"
  | "recover"
  | "login"
  | "admin";

/**
 * Where to go after signing in: `next` when it is an admin page path,
 * otherwise /admin (never another site or the sign-in page itself).
 */
export function afterLogin(next: string | null): string {
  return next && /^\/admin(\/[a-z]*)?$/.test(next) && next !== "/admin/login"
    ? next
    : "/admin";
}

/** The page that serves `pathname`, or null for an unknown path. */
export function pageFor(pathname: string): PageName | null {
  if (
    pathname === "/" || pathname === "/webirc" || pathname === "/status" ||
    pathname.startsWith("/channel/") || pathname.startsWith("/dm/")
  ) {
    return "webirc";
  }
  if (pathname === "/signup") return "signup";
  if (pathname === "/verify") return "verify";
  if (pathname === "/recover") return "recover";
  if (pathname === "/admin/login") return "login";
  if (pathname === "/admin" || pathname.startsWith("/admin/")) return "admin";
  return null;
}
