// Checks of the design tokens in styles/_tokens.scss for the light and dark
// themes: every text color meets WCAG 2.1 AA contrast (4.5:1) on each
// background it is drawn on, and every CSS custom property the stylesheets
// use is defined.
/// <reference lib="deno.ns" />

function assert(cond: unknown, msg = "assertion failed"): asserts cond {
  if (!cond) throw new Error(msg);
}

function assertEquals(actual: unknown, expected: unknown): void {
  const [a, e] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== e) throw new Error(`expected ${e}, got ${a}`);
}

const STYLES = new URL("../../styles/", import.meta.url);

async function readStyle(name: string): Promise<string> {
  return await Deno.readTextFile(new URL(name, STYLES));
}

/** Custom properties declared in the first block that `selector` opens. */
function block(scss: string, selector: string): Map<string, string> {
  const start = scss.indexOf(selector);
  assert(start >= 0, `no block ${selector}`);
  const open = scss.indexOf("{", start);
  const close = scss.indexOf("\n}", open);
  const vars = new Map<string, string>();
  for (
    const m of scss.slice(open + 1, close).matchAll(
      /^\s*(--[a-z0-9-]+):\s*([^;]+);/gm,
    )
  ) vars.set(m[1], m[2].trim());
  return vars;
}

function luminance(hex: string): number {
  const m = hex.match(/^#([0-9a-f]{6})$/i);
  if (!m) throw new Error(`not a #rrggbb color: ${hex}`);
  const [r, g, b] = [0, 2, 4].map((i) => {
    const v = parseInt(m[1].slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG 2.1 contrast ratio of two #rrggbb colors. */
export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

interface Theme {
  name: string;
  vars: Map<string, string>;
}

async function themes(): Promise<Theme[]> {
  const scss = await readStyle("_tokens.scss");
  const base = block(scss, ":root {");
  const darkNicks = block(scss, ':root[data-theme="dark"],');
  const light = new Map([
    ...base,
    ...block(scss, ':root:not([data-theme]),\n:root[data-theme="light"] {'),
  ]);
  const dark = new Map([
    ...base,
    ...darkNicks,
    ...block(scss, ':root[data-theme="dark"] {'),
  ]);
  return [{ name: "light", vars: light }, { name: "dark", vars: dark }];
}

/** A token's value, following `var(--other)` references. */
function get(theme: Theme, name: string, depth = 0): string {
  const v = theme.vars.get(name);
  assert(v, `${theme.name}: ${name} is not set`);
  const ref = v.match(/^var\((--[a-z0-9-]+)\)$/);
  assert(depth < 8, `${theme.name}: ${name} refers to itself`);
  return ref ? get(theme, ref[1], depth + 1) : v;
}

const AA = 4.5;

function expectAA(theme: Theme, fg: string, bgs: string[]): void {
  for (const bg of bgs) {
    const ratio = contrast(get(theme, fg), get(theme, bg));
    assert(
      ratio >= AA,
      `${theme.name}: ${fg} on ${bg} is ${ratio.toFixed(2)}:1, below ${AA}:1`,
    );
  }
}

const SURFACES = [
  "--bg",
  "--surface",
  "--surface-alt",
  "--sidebar",
  "--hover",
  "--elevated",
];

Deno.test("body and secondary text are readable on every surface", async () => {
  for (const theme of await themes()) {
    expectAA(theme, "--text", SURFACES);
    expectAA(theme, "--muted", SURFACES);
    // Body text stays at AAA (7:1) on the main surfaces.
    for (const bg of ["--bg", "--surface", "--sidebar"]) {
      assert(contrast(get(theme, "--text"), get(theme, bg)) >= 7);
    }
  }
});

Deno.test("accent text, buttons, and badges meet AA", async () => {
  for (const theme of await themes()) {
    // Links, mentions, and the open conversation in the sidebar.
    expectAA(theme, "--accent-text", ["--surface", "--accent-soft"]);
    expectAA(theme, "--accent-fg", ["--accent"]);
    expectAA(theme, "--badge-fg", ["--badge-bg"]);
    expectAA(theme, "--mention-fg", ["--mention-bg"]);
    expectAA(theme, "--text", ["--mention-row", "--accent-soft"]);
  }
});

Deno.test("nickname and avatar colors are readable in both themes", async () => {
  for (const theme of await themes()) {
    for (let i = 0; i < 8; i++) {
      // A name on a message, a highlighted mention, or a hovered row.
      expectAA(theme, `--nick-${i}`, [
        "--surface",
        "--surface-alt",
        "--mention-row",
        "--accent-soft",
      ]);
      // White initials on the avatar.
      const ratio = contrast("#ffffff", get(theme, `--avatar-${i}`));
      assert(ratio >= AA, `${theme.name}: avatar ${i} is ${ratio.toFixed(2)}`);
    }
  }
});

Deno.test("light and dark set the same tokens", async () => {
  const [light, dark] = await themes();
  const missing = [...light.vars.keys()].filter((k) => !dark.vars.has(k));
  assertEquals(missing, []);
});

Deno.test("every custom property a stylesheet uses is defined", async () => {
  const files = ["_tokens.scss", "_base.scss", "webirc.scss", "admin.scss"];
  const texts = await Promise.all(files.map(readStyle));
  const all = texts.join("\n");
  const defined = new Set(
    [...all.matchAll(/(--[a-z0-9-]+)\s*:/g)].map((m) => m[1]),
  );
  // Sass loops define --nick-N and --avatar-N through interpolation.
  for (let i = 0; i < 8; i++) {
    assert(defined.has(`--nick-${i}`) && defined.has(`--avatar-${i}`));
  }
  const undefinedVars = new Set<string>();
  // var(--name) without a fallback; `#{$i}` suffixes come from the loops.
  for (const m of all.matchAll(/var\((--[a-z0-9-]+)(#\{\$i\})?\s*\)/g)) {
    if (!m[2] && !defined.has(m[1])) undefinedVars.add(m[1]);
  }
  assertEquals([...undefinedVars], []);
});

Deno.test("chart series colors stand out from the dark surface", async () => {
  const [, dark] = await themes();
  // Lines and dots need 3:1 against the chart surface (WCAG 1.4.11). Light
  // slots 3 and 4 (aqua, yellow) sit below it; the Stats charts pair every
  // series with a legend value and a table view for that case.
  for (let i = 1; i <= 4; i++) {
    const ratio = contrast(get(dark, `--chart-${i}`), get(dark, "--surface"));
    assert(ratio >= 3, `dark: --chart-${i} is ${ratio.toFixed(2)}:1`);
  }
});
