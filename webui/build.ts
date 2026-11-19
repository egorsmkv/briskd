import * as esbuild from "esbuild";
import * as sass from "sass";

const outDir = "../priv/webui/assets";
await Deno.mkdir(outDir, { recursive: true });

const tsEntries = ["admin", "signup", "verify", "recover", "webirc"];
const scssEntries = ["admin", "signup", "verify", "recover", "webirc"];

const browserTargets = ["chrome80", "firefox78", "safari13", "edge80"];

await esbuild.build({
  entryPoints: tsEntries.map((name) => ({
    in: `src/${name}.ts`,
    out: name,
  })),
  outdir: outDir,
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2019", ...browserTargets],
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
