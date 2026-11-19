/// <reference lib="deno.ns" />
import {
  classifyFile,
  extractExt,
  formatBytes,
  isPreviewImageId,
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
