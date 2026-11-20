// The tab bar (WAI-ARIA tabs: roving tabindex; arrows, Home, and End move
// and activate) and the tab panel wrapper.
import type { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";
import { type Tab, TABS } from "./format.ts";
import { overview } from "./store.ts";

const LABELS: Record<Tab, string> = {
  overview: "Overview",
  clients: "Clients",
  channels: "Channels",
  links: "Links",
  accounts: "Accounts",
  dronebl: "DroneBL",
  media: "Features & Media",
  operations: "Operations",
};

/** Tab counts from the overview; tabs without one are absent. */
function counts(): Partial<Record<Tab, number>> {
  const d = overview.value;
  return {
    clients: d?.clients?.clients?.length ?? 0,
    channels: d?.channels?.channels?.length ?? 0,
    links: d?.links?.connected?.length ?? 0,
    accounts: d?.accounts?.accounts?.length ?? 0,
    dronebl: d?.dronebl?.bans?.length ?? 0,
  };
}

export function TabBar(
  { active, onSelect }: { active: Tab; onSelect: (tab: Tab) => void },
) {
  const refs = useRef<Partial<Record<Tab, HTMLButtonElement | null>>>({});
  const n = counts();

  useEffect(() => {
    refs.current[active]?.scrollIntoView?.({
      block: "nearest",
      inline: "nearest",
    });
  }, [active]);

  const onKeyDown = (ev: KeyboardEvent) => {
    const i = TABS.findIndex((t) => refs.current[t] === document.activeElement);
    if (i < 0) return;
    let j: number;
    if (ev.key === "ArrowRight") j = (i + 1) % TABS.length;
    else if (ev.key === "ArrowLeft") j = (i - 1 + TABS.length) % TABS.length;
    else if (ev.key === "Home") j = 0;
    else if (ev.key === "End") j = TABS.length - 1;
    else return;
    ev.preventDefault();
    refs.current[TABS[j]]?.focus();
    onSelect(TABS[j]);
  };

  return (
    <nav
      class="page-nav"
      id="tabs"
      role="tablist"
      aria-label="Admin sections"
      onKeyDown={onKeyDown}
    >
      <div class="page-nav-inner">
        {TABS.map((t) => {
          const selected = t === active;
          const count = n[t];
          return (
            <button
              key={t}
              ref={(b) => {
                refs.current[t] = b;
              }}
              type="button"
              class={selected ? "tab active" : "tab"}
              id={`tab-${t}`}
              data-tab={t}
              role="tab"
              aria-selected={selected ? "true" : "false"}
              aria-controls={`panel-${t}`}
              tabIndex={selected ? 0 : -1}
              onClick={() => onSelect(t)}
            >
              {LABELS[t]}
              {count !== undefined && (
                <>
                  {" "}
                  <span class="tab-count" id={`cnt-${t}`}>{count}</span>
                </>
              )}
            </button>
          );
        })}
      </div>
    </nav>
  );
}

/** A tab panel; only the active one is shown (.page.active). */
export function Panel(
  { tab, active, panel = true, children }: {
    tab: Tab;
    active: Tab;
    /** Add the boxed `.panel` style. */
    panel?: boolean;
    children: ComponentChildren;
  },
) {
  const cls = ["page", panel ? "panel" : "", tab === active ? "active" : ""]
    .filter(Boolean).join(" ");
  return (
    <section
      class={cls}
      id={`panel-${tab}`}
      role="tabpanel"
      aria-labelledby={`tab-${tab}`}
    >
      {children}
    </section>
  );
}
