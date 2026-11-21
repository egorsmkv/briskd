// The briskd admin panel (/admin, /admin/<tab>): server overview, stats charts
// (GET /api/stats, fetched while that tab is shown), clients,
// channels, links, accounts, DroneBL bans, media and feature toggles, and
// operations. Data comes from GET /api/overview (auto-refreshed every 5 s)
// and GET /api/media; actions go to POST /api/action.
import { useEffect, useState } from "preact/hooks";
import { navigate, pathname } from "../../router.ts";
import { type Tab, tabFromLocation, tabPath } from "./format.ts";
import {
  autoRefresh,
  connectionProblem,
  modal,
  refresh,
  refreshMedia,
} from "./store.ts";
import { Header } from "./Header.tsx";
import { Panel, TabBar } from "./Tabs.tsx";
import { Modal } from "./Modal.tsx";
import { Toasts } from "./Toasts.tsx";
import { OverviewTab } from "./OverviewTab.tsx";
import { ClientsTab } from "./ClientsTab.tsx";
import { ChannelsTab } from "./ChannelsTab.tsx";
import { LinksTab } from "./LinksTab.tsx";
import { AccountsTab } from "./AccountsTab.tsx";
import { DroneblTab } from "./DroneblTab.tsx";
import { MediaTab } from "./MediaTab.tsx";
import { OperationsTab } from "./OperationsTab.tsx";
import { StatsTab } from "./StatsTab.tsx";

/** Auto-refresh period of the overview, in milliseconds. */
const REFRESH_MS = 5000;

/** Periodic and on-visible refresh; cleared on unmount. */
function useAutoRefresh(): void {
  useEffect(() => {
    void refresh(true);
    // Skip the periodic refresh while a dialog is open or the tab is hidden,
    // so a re-render never moves the row the operator is acting on.
    const id = setInterval(() => {
      if (autoRefresh.value && !modal.value && !document.hidden) {
        void refresh();
      }
    }, REFRESH_MS);
    const onVisible = () => {
      if (!document.hidden && autoRefresh.value) void refresh();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(id);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);
}

/** The tab named by the URL; follows back/forward, including `#<tab>`. */
function useTab(): [Tab, (tab: Tab) => void] {
  const [, bump] = useState(0);
  useEffect(() => {
    const onPop = () => bump((n) => n + 1);
    addEventListener("popstate", onPop);
    addEventListener("hashchange", onPop);
    return () => {
      removeEventListener("popstate", onPop);
      removeEventListener("hashchange", onPop);
    };
  }, []);
  const tab = tabFromLocation(pathname.value, location.hash);
  const select = (next: Tab) => {
    const target = tabPath(next);
    if (location.pathname !== target || location.hash) navigate(target);
    else if (next === "media") void refreshMedia();
    bump((n) => n + 1);
  };
  return [tab, select];
}

export default function AdminPage() {
  useAutoRefresh();
  const [tab, select] = useTab();

  useEffect(() => {
    if (tab === "media") void refreshMedia();
  }, [tab]);

  const problem = connectionProblem.value;
  return (
    <>
      <Header />
      <TabBar active={tab} onSelect={select} />
      <main>
        <div
          id="notice"
          class={problem ? "err" : ""}
          role="status"
          aria-live="polite"
        >
          {problem ?? ""}
        </div>
        <Panel tab="overview" active={tab} panel={false}>
          <OverviewTab onGoto={select} />
        </Panel>
        <Panel tab="stats" active={tab} panel={false}>
          <StatsTab active={tab === "stats"} />
        </Panel>
        <Panel tab="clients" active={tab}>
          <ClientsTab />
        </Panel>
        <Panel tab="channels" active={tab}>
          <ChannelsTab />
        </Panel>
        <Panel tab="links" active={tab}>
          <LinksTab />
        </Panel>
        <Panel tab="accounts" active={tab}>
          <AccountsTab />
        </Panel>
        <Panel tab="dronebl" active={tab}>
          <DroneblTab />
        </Panel>
        <Panel tab="media" active={tab}>
          <MediaTab />
        </Panel>
        <Panel tab="operations" active={tab} panel={false}>
          <OperationsTab />
        </Panel>
      </main>
      <Modal />
      <Toasts />
    </>
  );
}
