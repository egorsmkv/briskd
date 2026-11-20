// Workspace settings: persistence, theme, the settings dialog, and feature switches.
import { byId as $ } from "../common/dom.ts";
import { currentLang, initLang, setLang, t } from "../common/i18n.ts";
import { currentTheme, initTheme, setTheme, THEMES } from "../common/theme.ts";
import {
  renderCallSettings,
  stopCallSettingsMedia,
} from "./call_settings_ui.ts";
import { renderE2eeModal, updateE2eeUi } from "./e2ee_ui.ts";
import { closeAttachMenu, closeCodeModal } from "./files.ts";
import { clearComposeMode } from "./message_actions.ts";
import { renderActiveMessages } from "./chat/list.ts";
import {
  closeDiscoverModal,
  closeModModal,
  closeTopicModal,
} from "./modals.ts";
import { closeDrawers, renderBuffers, renderMembers } from "./sidebar.ts";
import { buffers, S } from "./state.ts";
import { type FeatureKey, type WebircSettings } from "./types.ts";
import { renderTypingBar } from "./typing.ts";
import { isChan } from "./util.ts";

export const SETTINGS_KEY = "ircd-webirc-settings";

export function loadSettings(): WebircSettings {
  const defaults: WebircSettings = {
    layout: "auto",
    density: "comfortable",
    fontSize: "normal",
    timestamps: true,
    joinPart: true,
    notifyMentions: false,
    reactions: true,
    replies: true,
    typing: true,
    editing: true,
    redaction: true,
    linkPreviews: true,
    remoteAvatars: false,
  };
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return defaults;
    const parsed = JSON.parse(raw) as Partial<WebircSettings>;
    return {
      layout: parsed.layout === "mobile" || parsed.layout === "desktop"
        ? parsed.layout
        : "auto",
      density: parsed.density === "compact" ? "compact" : "comfortable",
      fontSize: parsed.fontSize === "small" || parsed.fontSize === "large"
        ? parsed.fontSize
        : "normal",
      timestamps: parsed.timestamps !== false,
      joinPart: parsed.joinPart !== false,
      notifyMentions: parsed.notifyMentions === true,
      reactions: parsed.reactions !== false,
      replies: parsed.replies !== false,
      typing: parsed.typing !== false,
      editing: parsed.editing !== false,
      redaction: parsed.redaction !== false,
      linkPreviews: parsed.linkPreviews !== false,
      remoteAvatars: parsed.remoteAvatars === true,
    };
  } catch {
    return defaults;
  }
}

export function saveSettings(s: WebircSettings): void {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
  } catch {
    // ignore
  }
}

export const serverFeatures: Record<FeatureKey, boolean> = {
  reactions: true,
  replies: true,
  typing: true,
  editing: true,
  redaction: true,
  link_previews: true,
};

export function featureOn(key: FeatureKey): boolean {
  if (key === "link_previews") {
    return serverFeatures.link_previews && settings.linkPreviews;
  }
  return serverFeatures[key] && settings[key];
}

export const settings: WebircSettings = loadSettings();

export function applySettings(): void {
  document.body.classList.toggle("layout-mobile", settings.layout === "mobile");
  document.body.classList.toggle(
    "layout-desktop",
    settings.layout === "desktop",
  );
  document.body.classList.toggle(
    "density-compact",
    settings.density === "compact",
  );
  document.body.classList.toggle("hide-timestamps", !settings.timestamps);
  document.body.classList.toggle("font-small", settings.fontSize === "small");
  document.body.classList.toggle("font-large", settings.fontSize === "large");
  $<HTMLSelectElement>("opt-lang").value = currentLang();
  $<HTMLSelectElement>("opt-layout").value = settings.layout;
  $<HTMLSelectElement>("opt-density").value = settings.density;
  $<HTMLSelectElement>("opt-fontsize").value = settings.fontSize;
  $<HTMLInputElement>("opt-timestamps").checked = settings.timestamps;
  $<HTMLInputElement>("opt-joinpart").checked = settings.joinPart;
  $<HTMLInputElement>("opt-notify").checked = settings.notifyMentions;
  $<HTMLInputElement>("opt-reactions").checked = settings.reactions;
  $<HTMLInputElement>("opt-replies").checked = settings.replies;
  $<HTMLInputElement>("opt-typing").checked = settings.typing;
  $<HTMLInputElement>("opt-editing").checked = settings.editing;
  $<HTMLInputElement>("opt-redaction").checked = settings.redaction;
  $<HTMLInputElement>("opt-link-previews").checked = settings.linkPreviews;
  $<HTMLInputElement>("opt-link-previews").disabled = !serverFeatures
    .link_previews;
  $<HTMLInputElement>("opt-remote-avatars").checked = settings.remoteAvatars;
  for (
    const key of [
      "reactions",
      "replies",
      "typing",
      "editing",
      "redaction",
    ] as const
  ) {
    const el = $<HTMLInputElement>(`opt-${key}`);
    el.disabled = !serverFeatures[key];
  }
}

export function renderThemeSwatches(): void {
  const grid = $("theme-grid");
  grid.textContent = "";
  const active = currentTheme();
  for (const t of THEMES) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "theme-swatch" + (t.id === active ? " active" : "");
    const chip = document.createElement("span");
    chip.className = "swatch-chip";
    chip.style.background =
      `linear-gradient(135deg, ${t.swatchBg} 0 58%, ${t.swatchAccent} 58% 100%)`;
    const label = document.createElement("span");
    label.textContent = t.name;
    btn.appendChild(chip);
    btn.appendChild(label);
    btn.onclick = () => {
      setTheme(t.id);
      renderThemeSwatches();
    };
    grid.appendChild(btn);
  }
}

export type SettingsTab = "general" | "calls" | "e2ee";

export function switchSettingsTab(tab: SettingsTab): void {
  for (const name of ["general", "calls", "e2ee"] as const) {
    const on = name === tab;
    $(`tab-settings-${name}`).classList.toggle("active", on);
    $(`tab-settings-${name}`).setAttribute("aria-selected", String(on));
    $(`pane-settings-${name}`).classList.toggle("active", on);
  }
  if (tab === "e2ee") renderE2eeModal();
  if (tab === "calls") renderCallSettings();
  else stopCallSettingsMedia();
}

export function openSettings(tab: SettingsTab = "general"): void {
  renderThemeSwatches();
  applySettings();
  switchSettingsTab(tab);
  $("settings-modal").classList.add("open");
}

export function closeSettings(): void {
  $("settings-modal").classList.remove("open");
  stopCallSettingsMedia();
}

/** Wire this module's DOM listeners and initial state. */
export function init(): void {
  initTheme([], {
    defaultTheme: "hacker",
    storageKey: "ircd-webirc-theme",
  });

  initLang();

  applySettings();

  $("btn-settings-1").onclick = () => openSettings("general");

  $("btn-settings-2").onclick = () => openSettings("general");

  $("btn-close-settings").onclick = closeSettings;

  $("tab-settings-general").onclick = () => switchSettingsTab("general");

  $("tab-settings-e2ee").onclick = () => switchSettingsTab("e2ee");

  $("tab-settings-calls").onclick = () => switchSettingsTab("calls");

  $("settings-modal").addEventListener("click", (ev) => {
    if (ev.target === $("settings-modal")) closeSettings();
  });

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") {
      closeSettings();
      closeTopicModal();
      closeCodeModal();
      closeModModal();
      closeAttachMenu();
      closeDiscoverModal();
      clearComposeMode();
    }
  });

  $<HTMLSelectElement>("opt-lang").onchange = (ev) => {
    const v = (ev.target as HTMLSelectElement).value;
    setLang(v === "he" ? "he" : "en");
    updateE2eeUi();
    renderBuffers();
    renderMembers();
    if ($("settings-modal").classList.contains("open")) renderE2eeModal();
    const buf = buffers.get(S.activeBuf);
    if (buf) {
      $("active-title").textContent = buf.name === "*status"
        ? t("status.title")
        : buf.name;
      $("active-topic").textContent = buf.topic ||
        (isChan(buf.name) ? t("topic.none") : "");
    }
  };

  $<HTMLSelectElement>("opt-layout").onchange = (ev) => {
    const v = (ev.target as HTMLSelectElement).value;
    settings.layout = v === "mobile" || v === "desktop" ? v : "auto";
    saveSettings(settings);
    applySettings();
    closeDrawers();
  };

  $<HTMLSelectElement>("opt-density").onchange = (ev) => {
    const v = (ev.target as HTMLSelectElement).value;
    settings.density = v === "compact" ? "compact" : "comfortable";
    saveSettings(settings);
    applySettings();
  };

  $<HTMLSelectElement>("opt-fontsize").onchange = (ev) => {
    const v = (ev.target as HTMLSelectElement).value;
    settings.fontSize = v === "small" || v === "large" ? v : "normal";
    saveSettings(settings);
    applySettings();
  };

  $<HTMLInputElement>("opt-timestamps").onchange = (ev) => {
    settings.timestamps = (ev.target as HTMLInputElement).checked;
    saveSettings(settings);
    applySettings();
  };

  $<HTMLInputElement>("opt-joinpart").onchange = (ev) => {
    settings.joinPart = (ev.target as HTMLInputElement).checked;
    saveSettings(settings);
    applySettings();
  };

  $<HTMLInputElement>("opt-notify").onchange = async (ev) => {
    const checked = (ev.target as HTMLInputElement).checked;
    if (
      checked && typeof Notification !== "undefined" &&
      Notification.permission === "default"
    ) {
      try {
        await Notification.requestPermission();
      } catch {
        // ignore
      }
    }
    settings.notifyMentions = checked;
    saveSettings(settings);
  };

  for (
    const key of [
      "reactions",
      "replies",
      "typing",
      "editing",
      "redaction",
    ] as const
  ) {
    $<HTMLInputElement>(`opt-${key}`).onchange = (ev) => {
      settings[key] = (ev.target as HTMLInputElement).checked;
      saveSettings(settings);
      if (!featureOn("typing")) renderTypingBar();
      if (!featureOn("replies") && S.composeMode?.kind === "reply") {
        clearComposeMode();
      }
      if (!featureOn("editing") && S.composeMode?.kind === "edit") {
        clearComposeMode();
      }
      renderActiveMessages();
    };
  }

  $<HTMLInputElement>("opt-link-previews").onchange = (ev) => {
    settings.linkPreviews = (ev.target as HTMLInputElement).checked;
    saveSettings(settings);
    renderActiveMessages();
  };

  $<HTMLInputElement>("opt-remote-avatars").onchange = (ev) => {
    settings.remoteAvatars = (ev.target as HTMLInputElement).checked;
    saveSettings(settings);
    renderActiveMessages();
  };
}
