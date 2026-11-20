import * as esbuild from "esbuild";
import * as sass from "sass";

const outDir = "../priv/webui/assets";
await Deno.mkdir(outDir, { recursive: true });

const tsEntries = ["admin", "signup", "verify", "recover", "webirc"];
const scssEntries = ["admin", "signup", "verify", "recover", "webirc"];

// Minimum browsers the shipped code actually needs (not just syntax, which
// esbuild lowers): regex lookbehind in common/format.ts (Safari 16.4),
// Element.replaceChildren (Chrome/Edge 86, Firefox 78), String.replaceAll and
// Blob.text. ES2020 is the newest edition Firefox 78 implements in full.
const browserTargets = ["chrome86", "firefox78", "safari16.4", "edge86"];

await esbuild.build({
  entryPoints: tsEntries.map((name) => ({
    in: `src/${name}.ts`,
    out: name,
  })),
  outdir: outDir,
  bundle: true,
  minify: true,
  format: "iife",
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
  `Built ${tsEntries.length} TS bundles and ${scssEntries.length} SCSS stylesheets into ${outDir}`,
);
