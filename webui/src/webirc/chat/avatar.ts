// The author's avatar: their metadata image, or initials on their color.
import { avatarOf } from "../users.ts";
import { nickColor } from "../util.ts";

export function createAvatar(nick: string): HTMLElement {
  const av = document.createElement("div");
  av.className = "avatar";
  av.style.backgroundColor = nickColor(nick);
  const initials = nick.slice(0, 2).toUpperCase();
  const url = avatarOf(nick);
  if (!url) {
    av.textContent = initials;
    return av;
  }
  const img = document.createElement("img");
  img.src = url;
  img.alt = "";
  img.loading = "lazy";
  img.decoding = "async";
  img.referrerPolicy = "no-referrer";
  img.onerror = () => {
    img.remove();
    av.classList.remove("has-img");
    av.textContent = initials;
  };
  av.classList.add("has-img");
  av.appendChild(img);
  return av;
}
