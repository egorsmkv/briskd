// A WebIRC video call between two headless Chromium tabs (fake camera and
// microphone) through briskd and a real rtpflux (test/calls/browser/run).
//
// alice starts it with /videocall; bob answers with video. Checks, each
// failing the run:
// - bob is told it is a video call, and each side decodes the other's video;
// - turning a camera off shows "Camera off" on the other side, and turning it
//   on again brings the picture back (both directions);
// - minimizing keeps the call, hanging up closes the stage on both sides and
//   records the call in the conversation;
// - no uncaught page error or console error.
// Screenshots go to /out (test/calls/browser/shots).
import puppeteer from "puppeteer-core";

const ORIGIN = "http://briskd:8081";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const failures = [];
const check = async (what, promise) => {
  try {
    await promise;
  } catch (e) {
    failures.push(`${what}: ${e.message}`);
  }
};

const browser = await puppeteer.launch({
  executablePath: "/usr/bin/chromium",
  args: [
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--use-fake-device-for-media-stream",
    "--use-fake-ui-for-media-stream",
    // getUserMedia needs a secure context; the test origin is plain HTTP.
    `--unsafely-treat-insecure-origin-as-secure=${ORIGIN}`,
    "--autoplay-policy=no-user-gesture-required",
  ],
});

async function open(nick, theme) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => failures.push(`${nick}: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error") failures.push(`${nick} console: ${m.text()}`);
  });
  await page.setViewport({ width: 1280, height: 800 });
  await page.evaluateOnNewDocument((session, theme) => {
    localStorage.setItem("briskd-webirc-theme", theme);
    sessionStorage.setItem("briskd-webirc-session", JSON.stringify(session));
  }, {
    nick,
    acct: "",
    pass: "",
    channels: [],
    wsUrl: "ws://briskd:8080/",
    activeBuf: "*status",
  }, theme);
  await page.goto(`${ORIGIN}/`, { waitUntil: "load" });
  await page.waitForFunction(
    () => document.getElementById("chat-view")?.classList.contains("active"),
    { timeout: 30000 },
  );
  await sleep(1500);
  return page;
}

const hasVideo = () =>
  document.getElementById("call-stage").classList.contains("has-video");
const noVideo = () =>
  !document.getElementById("call-stage").classList.contains("has-video");

/** Decoded frames of the remote video over two seconds. */
const framesOver2s = (page) =>
  page.evaluate(async () => {
    const v = document.getElementById("call-remote-video");
    const before = v.getVideoPlaybackQuality().totalVideoFrames;
    await new Promise((r) => setTimeout(r, 2000));
    return v.getVideoPlaybackQuality().totalVideoFrames - before;
  });

try {
  const alice = await open("alice", "light");
  const bob = await open("bob", "dark");

  await alice.type("#inp-msg", "/videocall bob");
  await alice.keyboard.press("Enter");
  await bob.waitForSelector("#call-incoming.open", { timeout: 20000 });
  const label = await bob.$eval("#call-incoming-label", (e) => e.textContent);
  if (label !== "Incoming video call") failures.push(`incoming label: ${label}`);
  await bob.screenshot({ path: "/out/1-bob-incoming.png" });
  await bob.click("#btn-call-accept-video");

  for (const [nick, page] of [["alice", alice], ["bob", bob]]) {
    await check(
      `${nick} receives video`,
      page.waitForFunction(
        () =>
          document.getElementById("call-remote-video").videoWidth > 0 &&
          document.getElementById("call-stage").classList.contains("has-video"),
        { timeout: 30000 },
      ),
    );
  }
  for (const [nick, page] of [["alice", alice], ["bob", bob]]) {
    const frames = await framesOver2s(page);
    console.log(`${nick} decoded ${frames} frames in 2 s`);
    if (!(frames > 10)) failures.push(`${nick}: remote video not playing (${frames})`);
  }
  await alice.screenshot({ path: "/out/2-alice-video.png" });
  await bob.screenshot({ path: "/out/2-bob-video.png" });

  // Camera off and on, each way.
  for (const [who, sees] of [[bob, alice], [alice, bob]]) {
    await who.click("#btn-call-camera");
    await check("camera off seen", sees.waitForFunction(noVideo, { timeout: 15000 }));
    const note = await sees.$eval("#call-stage-note", (e) => e.textContent);
    if (note !== "Camera off") failures.push(`camera off note: ${note}`);
    await who.click("#btn-call-camera");
    await check("camera on seen", sees.waitForFunction(hasVideo, { timeout: 15000 }));
  }
  await bob.screenshot({ path: "/out/3-bob-video-after-toggles.png" });

  await alice.click("#btn-call-stage-mini");
  await check(
    "minimized",
    alice.waitForFunction(
      () => document.getElementById("call-stage").classList.contains("mini"),
      { timeout: 5000 },
    ),
  );
  await alice.screenshot({ path: "/out/4-alice-minimized.png" });

  await alice.click("#btn-call-hangup");
  for (const [nick, page] of [["alice", alice], ["bob", bob]]) {
    await check(
      `${nick} stage closed`,
      page.waitForFunction(
        () => document.getElementById("call-stage").classList.contains("hidden"),
        { timeout: 15000 },
      ),
    );
  }
  const ended = await bob.evaluate(() =>
    [...document.querySelectorAll("#messages .msg")].some((m) =>
      m.textContent.includes("Call ended")
    )
  );
  if (!ended) failures.push("bob's conversation does not record the call");
  await bob.screenshot({ path: "/out/5-bob-ended.png" });
} catch (e) {
  failures.push(`script: ${e.message}`);
}

await browser.close();
if (failures.length) {
  console.log(`FAIL\n${failures.join("\n")}`);
  process.exit(1);
}
console.log("OK: video call in both directions, camera toggles, minimize, hangup");
