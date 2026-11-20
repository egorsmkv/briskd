// The app shell: picks the page for the current path, loads its code and
// stylesheet on first use, and shows it. The chat page stays mounted once
// opened (hidden on other pages), so visiting Sign Up or Recover keeps the
// IRC connection, and its controllers are initialised only once.
import type { ComponentType } from "preact";
import { useEffect, useState } from "preact/hooks";
import { config } from "./config.ts";
import { pathname } from "./router.ts";
import { pageFor, type PageName } from "./routes.ts";
import { NotFound } from "./components/NotFound.tsx";

type PageModule = { default: ComponentType };

const LOADERS: Record<PageName, () => Promise<PageModule>> = {
  webirc: () => import("./pages/webirc/WebircPage.tsx"),
  signup: () => import("./pages/auth/SignupPage.tsx"),
  verify: () => import("./pages/auth/VerifyPage.tsx"),
  recover: () => import("./pages/auth/RecoverPage.tsx"),
  admin: () => import("./pages/admin/AdminPage.tsx"),
};

/** Each page's stylesheet in /assets. */
const STYLES: Record<PageName, string> = {
  webirc: "webirc.css",
  signup: "signup.css",
  verify: "verify.css",
  recover: "recover.css",
  admin: "admin.css",
};

const TITLES: Record<PageName, string> = {
  webirc: "WebIRC",
  signup: "Sign Up",
  verify: "Verify Account",
  recover: "Recover Password",
  admin: "Admin",
};

/** Whether the server offers `page`. */
function available(page: PageName): boolean {
  const f = config().features;
  switch (page) {
    case "webirc":
      return f.webirc;
    case "signup":
      return f.registration;
    case "verify":
      return f.verification;
    case "recover":
      return f.recovery;
    case "admin":
      return true;
  }
}

const loaded = new Map<PageName, ComponentType>();

/**
 * Make `name` the page stylesheet: swap the <link id="page-style"> and
 * resolve once it has loaded, so a page never shows unstyled.
 */
function useStylesheet(name: string | null): boolean {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    if (!name) {
      setReady(true);
      return;
    }
    const href = `/assets/${name}`;
    let link = document.getElementById("page-style") as HTMLLinkElement | null;
    if (link && link.getAttribute("href") === href && link.sheet) {
      setReady(true);
      return;
    }
    setReady(false);
    const next = document.createElement("link");
    next.rel = "stylesheet";
    next.href = href;
    next.id = "page-style";
    const done = () => {
      // Drop the previous page's sheet only once the new one applies.
      if (link && link !== next) link.remove();
      link = next;
      setReady(true);
    };
    next.onload = done;
    next.onerror = done;
    if (link) link.id = "page-style-old";
    document.head.appendChild(next);
  }, [name]);
  return ready;
}

function usePage(page: PageName | null): ComponentType | null {
  const [, force] = useState(0);
  useEffect(() => {
    if (!page || loaded.has(page)) return;
    let live = true;
    LOADERS[page]().then((mod) => {
      loaded.set(page, mod.default);
      if (live) force((n) => n + 1);
    });
    return () => {
      live = false;
    };
  }, [page]);
  return page ? loaded.get(page) ?? null : null;
}

export function App() {
  const route = pageFor(pathname.value);
  const page = route && available(route) ? route : null;
  const styleReady = useStylesheet(page ? STYLES[page] : "signup.css");
  const Page = usePage(page);
  const Chat = usePage(page === "webirc" ? "webirc" : null) ??
    loaded.get("webirc") ?? null;

  useEffect(() => {
    if (page !== "webirc") {
      document.title = `${
        page ? TITLES[page] : "Not Found"
      } - ${config().network}`;
    }
  }, [page]);

  return (
    <>
      {
        /* The chat, once opened, stays mounted and keeps its connection. */
        Chat && (
          <div class="page-webirc" hidden={page !== "webirc" || !styleReady}>
            <Chat />
          </div>
        )
      }
      {page !== "webirc" && (
        !page ? (styleReady && <NotFound />) : (Page && styleReady && <Page />)
      )}
    </>
  );
}
