// Touch gestures: edge swipe to open or close the conversations drawer.
import { byId as $ } from "../common/dom.ts";
import { closeDrawers, toggleDrawer } from "./sidebar.ts";
import { S } from "./state.ts";

// Edge swipe gesture to open/close Channels drawer on touch devices

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  document.addEventListener("touchstart", (ev) => {
    if (ev.touches.length !== 1) return;
    const x = ev.touches[0].clientX;
    const y = ev.touches[0].clientY;
    const isRtl = document.documentElement.dir === "rtl";
    const drawerOpen = $("sidebar-left").classList.contains("open");
    const nearEdge = isRtl ? x > globalThis.innerWidth - 28 : x < 28;
    if (nearEdge || drawerOpen) {
      S.edgeStartX = x;
      S.edgeStartY = y;
      S.edgeActive = true;
    } else {
      S.edgeActive = false;
    }
  }, { passive: true });

  document.addEventListener("touchend", (ev) => {
    if (!S.edgeActive || ev.changedTouches.length !== 1) return;
    S.edgeActive = false;
    const dx = ev.changedTouches[0].clientX - S.edgeStartX;
    const dy = ev.changedTouches[0].clientY - S.edgeStartY;
    if (Math.abs(dx) < 56 || Math.abs(dx) < Math.abs(dy) * 1.5) return;
    const isRtl = document.documentElement.dir === "rtl";
    const openSwipe = isRtl ? dx < 0 : dx > 0;
    const drawerOpen = $("sidebar-left").classList.contains("open");
    if (openSwipe && !drawerOpen) {
      toggleDrawer("left");
    } else if (!openSwipe && drawerOpen) {
      closeDrawers();
    }
  }, { passive: true });
}
