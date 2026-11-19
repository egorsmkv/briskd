/**
 * Zero-dependency full-screen Image Lightbox with multi-image album navigation,
 * click-to-zoom, download button, and full keyboard support (Escape, Left/Right, +/-).
 */

export interface LightboxItem {
  url: string;
  name: string;
  sizeText?: string;
  encrypted?: boolean;
}

let overlayEl: HTMLDivElement | null = null;
let keyHandler: ((ev: KeyboardEvent) => void) | null = null;

export function closeLightbox(): void {
  if (overlayEl) {
    overlayEl.remove();
    overlayEl = null;
  }
  if (keyHandler) {
    document.removeEventListener("keydown", keyHandler);
    keyHandler = null;
  }
}

export function openLightbox(items: LightboxItem[], startIndex = 0): void {
  if (items.length === 0) return;
  closeLightbox();

  let index = Math.max(0, Math.min(items.length - 1, startIndex));
  let zoomed = false;

  const overlay = document.createElement("div");
  overlay.className = "lightbox-backdrop";
  overlay.setAttribute("role", "dialog");
  overlay.setAttribute("aria-modal", "true");
  overlay.setAttribute("aria-label", "Image viewer");

  const topbar = document.createElement("div");
  topbar.className = "lightbox-top";

  const caption = document.createElement("div");
  caption.className = "lightbox-caption";

  const counterEl = document.createElement("span");
  counterEl.className = "lightbox-counter";

  const nameEl = document.createElement("span");
  nameEl.className = "lightbox-name";
  nameEl.dir = "auto";

  const badgeEl = document.createElement("span");
  badgeEl.className = "msg-e2ee hidden";
  badgeEl.textContent = "E2EE";

  caption.appendChild(counterEl);
  caption.appendChild(nameEl);
  caption.appendChild(badgeEl);

  const controls = document.createElement("div");
  controls.className = "lightbox-controls";

  const zoomBtn = document.createElement("button");
  zoomBtn.type = "button";
  zoomBtn.className = "lightbox-btn";
  zoomBtn.textContent = "🔍";
  zoomBtn.title = "Toggle zoom";
  zoomBtn.setAttribute("aria-label", "Toggle zoom");

  const dlLink = document.createElement("a");
  dlLink.className = "lightbox-btn";
  dlLink.textContent = "⬇";
  dlLink.title = "Download";
  dlLink.setAttribute("aria-label", "Download image");
  dlLink.rel = "noopener noreferrer";

  const closeBtn = document.createElement("button");
  closeBtn.type = "button";
  closeBtn.className = "lightbox-btn";
  closeBtn.textContent = "×";
  closeBtn.title = "Close (Esc)";
  closeBtn.setAttribute("aria-label", "Close image viewer");

  controls.appendChild(zoomBtn);
  controls.appendChild(dlLink);
  controls.appendChild(closeBtn);
  topbar.appendChild(caption);
  topbar.appendChild(controls);

  const stage = document.createElement("div");
  stage.className = "lightbox-stage";

  const prevBtn = document.createElement("button");
  prevBtn.type = "button";
  prevBtn.className = "lightbox-nav lightbox-prev";
  prevBtn.textContent = "‹";
  prevBtn.setAttribute("aria-label", "Previous image");

  const img = document.createElement("img");
  img.className = "lightbox-img";

  const nextBtn = document.createElement("button");
  nextBtn.type = "button";
  nextBtn.className = "lightbox-nav lightbox-next";
  nextBtn.textContent = "›";
  nextBtn.setAttribute("aria-label", "Next image");

  stage.appendChild(prevBtn);
  stage.appendChild(img);
  stage.appendChild(nextBtn);

  overlay.appendChild(topbar);
  overlay.appendChild(stage);

  function render(): void {
    const item = items[index];
    zoomed = false;
    img.classList.remove("zoomed");
    img.src = item.url;
    img.alt = item.name;
    nameEl.textContent = item.sizeText
      ? `${item.name} (${item.sizeText})`
      : item.name;
    badgeEl.classList.toggle("hidden", !item.encrypted);
    dlLink.href = item.url;
    dlLink.download = item.name;
    const multi = items.length > 1;
    counterEl.textContent = multi ? `${index + 1} / ${items.length}` : "";
    counterEl.classList.toggle("hidden", !multi);
    prevBtn.classList.toggle("hidden", !multi);
    nextBtn.classList.toggle("hidden", !multi);
  }

  function step(delta: number): void {
    if (items.length <= 1) return;
    index = (index + delta + items.length) % items.length;
    render();
  }

  function toggleZoom(): void {
    zoomed = !zoomed;
    img.classList.toggle("zoomed", zoomed);
  }

  prevBtn.onclick = (ev) => {
    ev.stopPropagation();
    step(-1);
  };
  nextBtn.onclick = (ev) => {
    ev.stopPropagation();
    step(1);
  };
  zoomBtn.onclick = (ev) => {
    ev.stopPropagation();
    toggleZoom();
  };
  img.onclick = (ev) => {
    ev.stopPropagation();
    toggleZoom();
  };
  closeBtn.onclick = () => closeLightbox();
  overlay.addEventListener("click", (ev) => {
    if (ev.target === overlay || ev.target === stage) closeLightbox();
  });

  // Touch swipe left/right for album navigation on iPhone/mobile
  let swipeStartX = 0;
  let swipeStartY = 0;
  stage.addEventListener("touchstart", (ev) => {
    if (ev.touches.length === 1) {
      swipeStartX = ev.touches[0].clientX;
      swipeStartY = ev.touches[0].clientY;
    }
  }, { passive: true });
  stage.addEventListener("touchend", (ev) => {
    if (zoomed || ev.changedTouches.length !== 1) return;
    const dx = ev.changedTouches[0].clientX - swipeStartX;
    const dy = ev.changedTouches[0].clientY - swipeStartY;
    if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.4) {
      step(dx < 0 ? 1 : -1);
    }
  }, { passive: true });

  keyHandler = (ev: KeyboardEvent) => {
    if (ev.key === "Escape") {
      ev.preventDefault();
      closeLightbox();
    } else if (ev.key === "ArrowLeft") {
      ev.preventDefault();
      step(-1);
    } else if (ev.key === "ArrowRight") {
      ev.preventDefault();
      step(1);
    } else if (ev.key === "+" || ev.key === "=" || ev.key === " ") {
      ev.preventDefault();
      toggleZoom();
    }
  };
  document.addEventListener("keydown", keyHandler);

  render();
  document.body.appendChild(overlay);
  overlayEl = overlay;
}
