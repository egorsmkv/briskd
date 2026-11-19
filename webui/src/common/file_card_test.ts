/// <reference lib="deno.ns" />
import {
  classifyFile,
  E2EE_ATT_PREFIX,
  extractExt,
  formatBytes,
  isPreviewImageId,
  parseE2eeAttachment,
  sanitizeDisplayName,
} from "./file_card.ts";

function assert(cond: boolean, msg: string): void {
  if (!cond) throw new Error(`Assertion failed: ${msg}`);
}

Deno.test("formatBytes formats byte counts concisely", () => {
  assert(formatBytes(0) === "", "0 bytes");
  assert(formatBytes(512) === "512 B", "bytes");
  assert(formatBytes(2048) === "2.0 KB", "kilobytes");
  assert(formatBytes(1572864) === "1.5 MB", "megabytes");
  assert(formatBytes(2147483648) === "2.00 GB", "gigabytes");
});

Deno.test("extractExt and classifyFile categorize files safely", () => {
  assert(extractExt("photo.PNG") === "png", "lowercase ext");
  assert(extractExt("noext") === "bin", "fallback bin");
  assert(classifyFile("abc.png").kind === "image", "image");
  assert(classifyFile("doc.pdf").kind === "pdf", "pdf");
  assert(classifyFile("pkg.zip").kind === "archive", "archive");
  assert(classifyFile("notes.md").kind === "text", "text");
  assert(classifyFile("clip.mp4").kind === "media", "media");
  assert(classifyFile("blob.bin").kind === "file", "file");
});

Deno.test("isPreviewImageId only allows safe raster formats", () => {
  assert(isPreviewImageId("0123456789abcdef0123456789abcdef.png"), "png");
  assert(isPreviewImageId("0123456789abcdef0123456789abcdef.webp"), "webp");
  assert(!isPreviewImageId("0123456789abcdef0123456789abcdef.svg"), "no svg");
  assert(!isPreviewImageId("0123456789abcdef0123456789abcdef.pdf"), "no pdf");
  assert(!isPreviewImageId("0123456789abcdef0123456789abcdef.bin"), "no bin");
});

Deno.test("parseE2eeAttachment validates payloads and rejects traversal IDs", () => {
  const goodVoice = E2EE_ATT_PREFIX + JSON.stringify({
    v: 1,
    kind: "voice",
    id: "0123456789abcdef0123456789abcdef.bin",
    mime: "audio/ogg",
    dur: 5,
    bytes: 1234,
    key: "a",
    iv: "b",
    sha256: "c",
  });
  const parsed = parseE2eeAttachment(goodVoice);
  assert(parsed !== null && parsed.kind === "voice", "valid voice payload");

  const badId = E2EE_ATT_PREFIX + JSON.stringify({
    v: 1,
    kind: "file",
    id: "../secret.bin",
    name: "x.txt",
    mime: "text/plain",
    bytes: 10,
    key: "a",
    iv: "b",
    sha256: "c",
  });
  assert(parseE2eeAttachment(badId) === null, "must reject traversal id");
  assert(parseE2eeAttachment("plain text") === null, "ignores normal text");
});

Deno.test("sanitizeDisplayName strips paths, control chars, and RLO spoofing", () => {
  assert(
    sanitizeDisplayName("../../invoice\u202Egpj.exe") === "invoicegpj.exe",
    "strips traversal and RLO",
  );
  assert(sanitizeDisplayName("a\r\nb.txt") === "ab.txt", "strips CRLF");
  assert(sanitizeDisplayName("   ") === "file.bin", "fallback");
});
