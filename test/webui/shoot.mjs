// WebIRC in headless Chromium, light and dark themes (test/webui/run).
//
// For each theme it opens the connect page and a busy channel at desktop and
// phone width, takes screenshots (members panel, @-mention list, settings,
// the hover action bar, the phone drawer), and checks:
// - no uncaught page error or console error;
// - each probed text color has at least 4.5:1 contrast (WCAG 2.1 AA) with
//   the nearest opaque background behind it.
// Exits 1 when a check fails. Screenshots go to /out (test/webui/shots).
import puppeteer from "puppeteer-core";
import net from "node:net";

const HOST = process.env.WEBUI_HOST || "ircd";
const OUT = `/out/${process.argv[2] || "webirc"}`;
const THEMES = (process.env.THEMES || "light,dark").split(",");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const failures = [];

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/chromium",
  args: ["--no-sandbox", "--disable-dev-shm-usage", "--font-render-hinting=none"],
});

// Other people in the channels, as plain IRC clients.
const people = {};
function person(nick, channels) {
  const s = net.connect(6667, HOST);
  s.on("data", (d) => {
    for (const l of d.toString().split("\r\n")) {
      if (l.startsWith("PING")) s.write(`PONG${l.slice(4)}\r\n`);
    }
  });
  const real = nick[0].toUpperCase() + nick.slice(1);
  s.write(`NICK ${nick}\r\nUSER ${nick} 0 * :${real} Example\r\n`);
  for (const c of channels) s.write(`JOIN ${c}\r\n`);
  people[nick] = s;
}
const say = (nick, target, text) => people[nick].write(`PRIVMSG ${target} :${text}\r\n`);
for (const n of ["alice", "bob", "carol", "dmitri", "eve", "frank"]) {
  person(n, ["#design", "#general"]);
}
people.alice.write("TOPIC #design :Design review — mockups due Friday\r\n");
people.eve.write("AWAY :in a meeting\r\n");
await sleep(1000);

async function open(theme, viewport, path, session) {
  const page = await browser.newPage();
  page.on("pageerror", (e) => failures.push(`${theme} ${path}: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") failures.push(`${theme} ${path} console: ${m.text()}`);
  });
  await page.setViewport(viewport);
  await page.evaluateOnNewDocument((theme, session) => {
    localStorage.setItem("ircd-webirc-theme", theme);
    if (session) sessionStorage.setItem("ircd-webirc-session", JSON.stringify(session));
  }, theme, session);
  await page.emulateMediaFeatures([
    { name: "prefers-color-scheme", value: theme === "light" ? "light" : "dark" },
  ]);
  await page.goto(`http://${HOST}:8081${path}`, { waitUntil: "load" });
  return page;
}

const desktop = { width: 1440, height: 900 };
const phone = { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
const session = (nick) => ({
  nick,
  acct: "",
  pass: "",
  channels: ["#design", "#general"],
  wsUrl: `ws://${HOST}:8080/`,
  activeBuf: "#design",
});
const shot = (page, name, clip) => page.screenshot({ path: `${OUT}-${name}.png`, clip });
const openBuf = (page, name) =>
  page.evaluate((name) => {
    [...document.querySelectorAll(".buf-item")].find((e) => e.title === name)?.click();
  }, name);
const waitForMessages = (page) =>
  page.waitForFunction(() => document.querySelectorAll("#messages .msg").length > 0, {
    timeout: 30000,
  });

async function traffic(me) {
  const lines = [
    () => say("alice", "#design", "Morning! I pushed the new sidebar mockups to the shared folder."),
    () => say("alice", "#design", "The spacing on the member list still feels a bit tight to me."),
    () => say("bob", "#design", `${me}: can you check the contrast in dark mode?`),
    () =>
      say(
        "carol",
        "#design",
        "Agreed. A longer note to see how a message wraps across several lines in a wide window, with a link https://example.org/notes in the middle.",
      ),
    () => people.dmitri.write("PART #design :lunch\r\n"),
    () => say("eve", "#design", "\u0001ACTION waves at everyone\u0001"),
    () => say("frank", "#design", "`deno task build` passes now, ship it?"),
    () => say("alice", "#general", "unread in general"),
    () => say("bob", me, "hey, quick question about the release"),
  ];
  for (const line of lines) {
    line();
    await sleep(120);
  }
  await sleep(1200);
  people.dmitri.write("JOIN #design\r\n");
}

// Contrast of each probed text against the nearest opaque background.
function contrastReport(page, theme) {
  return page.evaluate((theme) => {
    const parse = (c) => c.match(/[\d.]+/g)?.map(Number);
    const lum = ([r, g, b]) => {
      const f = (v) => {
        v /= 255;
        return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
    };
    const background = (el) => {
      for (let e = el; e; e = e.parentElement) {
        const c = parse(getComputedStyle(e).backgroundColor);
        if (c && (c.length < 4 || c[3] > 0.9)) return c;
      }
      return [255, 255, 255];
    };
    const probes = [
      ".msg .msg-text",
      ".msg-nick",
      ".msg-time",
      ".msg.sys",
      ".msg.mention .msg-text",
      ".head-title",
      ".head-topic",
      ".section-label",
      ".buf-item:not(.active) .buf-name",
      ".buf-item.active .buf-name",
      ".buf-badge",
      ".buf-badge.mention",
      ".me-state",
      ".composer-hint",
      ".conv-intro p",
      ".day-divider",
    ];
    return probes.flatMap((sel) =>
      [...document.querySelectorAll(sel)].slice(0, 6).map((el) => {
        const [a, b] = [lum(parse(getComputedStyle(el).color)), lum(background(el))].sort(
          (x, y) => y - x,
        );
        return { theme, sel, ratio: (a + 0.05) / (b + 0.05) };
      })
    );
  }, theme);
}

for (const theme of THEMES) {
  let page = await open(theme, desktop, "/", null);
  await sleep(700);
  await shot(page, `connect-${theme}`);
  await page.close();
  page = await open(theme, phone, "/", null);
  await sleep(700);
  await shot(page, `connect-${theme}-phone`);
  await page.close();

  const me = `me_${theme}`;
  page = await open(theme, desktop, "/channel/design", session(me));
  await waitForMessages(page);
  await traffic(me);
  await openBuf(page, "#design");
  await sleep(500);
  await shot(page, `chat-${theme}`);
  for (const r of await contrastReport(page, theme)) {
    if (r.ratio < 4.5) failures.push(`${r.theme} ${r.sel}: contrast ${r.ratio.toFixed(2)}:1`);
  }
  const rows = await page.$$("#messages .msg[data-msgid]");
  await rows[Math.min(2, rows.length - 1)].hover();
  await sleep(300);
  await shot(page, `hover-${theme}`, { x: 252, y: 56, width: 1188, height: 420 });
  await page.click("#btn-members");
  await sleep(400);
  await shot(page, `members-${theme}`);
  await page.click("#btn-members");
  await page.focus("#inp-msg");
  await page.keyboard.type("Thanks @a");
  await sleep(300);
  await shot(page, `mention-${theme}`);
  await page.keyboard.press("Escape");
  await page.click("#btn-settings-2");
  await sleep(500);
  await shot(page, `settings-${theme}`);
  await page.close();

  const pm = `ph_${theme}`;
  page = await open(theme, phone, "/channel/design", session(pm));
  await waitForMessages(page);
  await traffic(pm);
  await openBuf(page, "#design");
  await sleep(500);
  await shot(page, `chat-${theme}-phone`);
  await page.click("#btn-menu");
  await sleep(500);
  await shot(page, `drawer-${theme}-phone`);
  await page.close();
}

await browser.close();
for (const s of Object.values(people)) s.end();
if (failures.length) {
  console.error(`FAIL\n${failures.join("\n")}`);
  process.exit(1);
}
console.log(`OK: ${THEMES.join(", ")}; screenshots in test/webui/shots`);
