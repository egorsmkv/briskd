import * as esbuild from "esbuild";
import * as sass from "sass";

const outDir = "../priv/webui/assets";
await Deno.mkdir(outDir, { recursive: true });

// One single-page app (src/app/main.tsx) serves every page. Each page is a
// lazily loaded chunk (ESM code splitting), so the chat does not download
// the admin code and the other way round.
const scssEntries = ["admin", "signup", "verify", "recover", "webirc"];

// Minimum browsers the shipped code actually needs (not just syntax, which
// esbuild lowers): regex lookbehind in common/format.ts (Safari 16.4),
// Element.replaceChildren (Chrome/Edge 86, Firefox 78), String.replaceAll and
// Blob.text. ES2020 is the newest edition Firefox 78 implements in full; ESM
// dynamic import() is in all of these.
const browserTargets = ["chrome86", "firefox78", "safari16.4", "edge86"];

// Remove bundles from earlier builds (old per-page scripts, stale chunks).
for await (const entry of Deno.readDir(outDir)) {
  if (entry.isFile && entry.name.endsWith(".js")) {
    await Deno.remove(`${outDir}/${entry.name}`);
  }
}

await esbuild.build({
  entryPoints: [{ in: "src/app/main.tsx", out: "app" }],
  outdir: outDir,
  bundle: true,
  splitting: true,
  format: "esm",
  chunkNames: "chunk-[hash]",
  minify: true,
  jsx: "automatic",
  jsxImportSource: "preact",
  target: ["es2020", ...browserTargets],
  sourcemap: false,
});

for (const name of scssEntries) {
  const compiled = sass.compile(`styles/${name}.scss`, {
    style: "expanded",
    loadPaths: ["styles"],
  });
  const lowered = await esbuild.transform(compiled.css, {
    loader: "css",
    minify: true,
    target: browserTargets,
  });
  await Deno.writeTextFile(`${outDir}/${name}.css`, lowered.code);
}

await esbuild.stop();
console.log(
  `Built the app bundle and ${scssEntries.length} SCSS stylesheets into ${outDir}`,
);
