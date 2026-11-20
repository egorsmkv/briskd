// Line icons on a 24-unit grid (2px stroke, round joins), shared by the TSX
// views (app/components/Icon.tsx) and code that builds the DOM directly.
// SVG instead of emoji or text glyphs: they render the same on every
// platform, follow the text color, and need no icon font.

type Shape = [tag: string, attrs: Record<string, string>];

export const ICONS = {
  hash: [
    ["line", { x1: "4", y1: "9", x2: "20", y2: "9" }],
    ["line", { x1: "4", y1: "15", x2: "20", y2: "15" }],
    ["line", { x1: "10", y1: "3", x2: "8", y2: "21" }],
    ["line", { x1: "16", y1: "3", x2: "14", y2: "21" }],
  ],
  lock: [
    ["rect", { x: "3", y: "11", width: "18", height: "11", rx: "2" }],
    ["path", { d: "M7 11V7a5 5 0 0 1 10 0v4" }],
  ],
  unlock: [
    ["rect", { x: "3", y: "11", width: "18", height: "11", rx: "2" }],
    ["path", { d: "M7 11V7a5 5 0 0 1 9.9-1" }],
  ],
  server: [
    ["rect", { x: "2", y: "3", width: "20", height: "8", rx: "2" }],
    ["rect", { x: "2", y: "13", width: "20", height: "8", rx: "2" }],
    ["line", { x1: "6", y1: "7", x2: "6.01", y2: "7" }],
    ["line", { x1: "6", y1: "17", x2: "6.01", y2: "17" }],
  ],
  menu: [
    ["line", { x1: "3", y1: "6", x2: "21", y2: "6" }],
    ["line", { x1: "3", y1: "12", x2: "21", y2: "12" }],
    ["line", { x1: "3", y1: "18", x2: "21", y2: "18" }],
  ],
  x: [
    ["line", { x1: "18", y1: "6", x2: "6", y2: "18" }],
    ["line", { x1: "6", y1: "6", x2: "18", y2: "18" }],
  ],
  plus: [
    ["line", { x1: "12", y1: "5", x2: "12", y2: "19" }],
    ["line", { x1: "5", y1: "12", x2: "19", y2: "12" }],
  ],
  search: [
    ["circle", { cx: "11", cy: "11", r: "7" }],
    ["line", { x1: "21", y1: "21", x2: "16.65", y2: "16.65" }],
  ],
  compass: [
    ["circle", { cx: "12", cy: "12", r: "10" }],
    [
      "polygon",
      { points: "16.24 7.76 14.12 14.12 7.76 16.24 9.88 9.88 16.24 7.76" },
    ],
  ],
  pencil: [
    ["path", { d: "M12 20h9" }],
    ["path", { d: "M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" }],
  ],
  users: [
    ["path", { d: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" }],
    ["circle", { cx: "9", cy: "7", r: "4" }],
    ["path", { d: "M22 21v-2a4 4 0 0 0-3-3.87" }],
    ["path", { d: "M16 3.13a4 4 0 0 1 0 7.75" }],
  ],
  login: [
    ["path", { d: "M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" }],
    ["polyline", { points: "10 17 15 12 10 7" }],
    ["line", { x1: "15", y1: "12", x2: "3", y2: "12" }],
  ],
  logout: [
    ["path", { d: "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" }],
    ["polyline", { points: "16 17 21 12 16 7" }],
    ["line", { x1: "21", y1: "12", x2: "9", y2: "12" }],
  ],
  refresh: [
    ["polyline", { points: "23 4 23 10 17 10" }],
    ["path", { d: "M20.49 15a9 9 0 1 1-2.12-9.36L23 10" }],
  ],
  chevronDown: [["polyline", { points: "6 9 12 15 18 9" }]],
  reply: [
    ["polyline", { points: "9 14 4 9 9 4" }],
    ["path", { d: "M20 20v-7a4 4 0 0 0-4-4H4" }],
  ],
  trash: [
    ["polyline", { points: "3 6 5 6 21 6" }],
    ["path", { d: "M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" }],
    ["path", { d: "M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2" }],
  ],
  ban: [
    ["circle", { cx: "12", cy: "12", r: "9" }],
    ["line", { x1: "5.6", y1: "5.6", x2: "18.4", y2: "18.4" }],
  ],
  at: [
    ["circle", { cx: "12", cy: "12", r: "4" }],
    ["path", { d: "M16 8v5a3 3 0 0 0 6 0v-1a10 10 0 1 0-3.92 7.94" }],
  ],
} satisfies Record<string, Shape[]>;

export type IconName = keyof typeof ICONS;

const NS = "http://www.w3.org/2000/svg";

/** An `<svg>` icon element; decorative (aria-hidden) unless labelled. */
export function iconEl(name: IconName, size = 16, cls = "icon"): SVGSVGElement {
  const svg = document.createElementNS(NS, "svg");
  for (
    const [k, v] of Object.entries({
      class: cls,
      viewBox: "0 0 24 24",
      width: String(size),
      height: String(size),
      fill: "none",
      stroke: "currentColor",
      "stroke-width": "2",
      "stroke-linecap": "round",
      "stroke-linejoin": "round",
      "aria-hidden": "true",
      focusable: "false",
    })
  ) svg.setAttribute(k, v);
  for (const [tag, attrs] of ICONS[name] as Shape[]) {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    svg.appendChild(el);
  }
  return svg;
}
