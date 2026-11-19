import * as esbuild from "esbuild";
import * as sass from "sass";

const outDir = "../priv/webui/assets";
await Deno.mkdir(outDir, { recursive: true });

const tsEntries = ["admin", "signup", "verify", "webirc"];
const scssEntries = ["admin", "signup", "verify", "webirc"];

await esbuild.build({
  entryPoints: tsEntries.map((name) => ({
    in: `src/${name}.ts`,
    out: name,
  })),
  outdir: outDir,
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2022"],
  sourcemap: false,
});

for (const name of scssEntries) {
  const result = sass.compile(`styles/${name}.scss`, {
    style: "compressed",
    loadPaths: ["styles"],
  });
  await Deno.writeTextFile(`${outDir}/${name}.css`, result.css);
}

await esbuild.stop();
console.log(`Built ${tsEntries.length} TS bundles and ${scssEntries.length} SCSS stylesheets into ${outDir}`);
