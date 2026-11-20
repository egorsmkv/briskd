// The shared line icons (common/icons.ts) as a TSX component.
import { h } from "preact";
import { type IconName, ICONS } from "../../common/icons.ts";

export function Icon(
  { name, size = 16, class: cls = "icon", id, hidden }: {
    name: IconName;
    size?: number;
    class?: string;
    id?: string;
    hidden?: boolean;
  },
) {
  return (
    <svg
      class={hidden ? `${cls} hidden` : cls}
      id={id}
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {(ICONS[name] as Array<[string, Record<string, string>]>).map((
        [tag, attrs],
      ) => h(tag, attrs))}
    </svg>
  );
}
