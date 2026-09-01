// Build an obfuscated, distributable copy of the extension into ./dist.
//
// Browser extensions ship as plain text — there is no way to make the shipped
// code unreadable. Obfuscation raises the cost of reading and editing the
// source; it is not encryption and does not prevent a determined reader.
//
// What this does:
//   * JS  -> heavily obfuscated (renaming, string array + encoding, control
//            flow flattening, dead code, self-defending, debug protection)
//   * CSS -> copied as-is (styling is not sensitive)
//   * HTML-> copied as-is (Chrome must parse it; scripts it loads are obfuscated)
//   * manifest.json, icons -> copied verbatim (Chrome must read the manifest)

import { readFile, writeFile, mkdir, rm, cp } from "node:fs/promises";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import JavaScriptObfuscator from "javascript-obfuscator";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");

// Files loaded together in the same context. Merge order matters: labels.js
// defines ZAA_LABELS that content.js reads, so it must come first. Merging the
// pair lets the obfuscator rename that shared global too, instead of leaving it
// exposed as a well-known name across two separate files.
const bundles = [
  { out: "content.js", inputs: ["labels.js", "content.js"] },
  { out: "background.js", inputs: ["background.js"] },
  { out: "popup.js", inputs: ["popup.js"] }
];

const copyAsIs = ["popup.html", "popup.css"];
const copyDirs = ["icons"];

const obfuscatorOptions = {
  compact: true,
  controlFlowFlattening: true,
  controlFlowFlatteningThreshold: 0.75,
  deadCodeInjection: true,
  deadCodeInjectionThreshold: 0.4,
  debugProtection: true,
  debugProtectionInterval: 2000,
  disableConsoleOutput: false, // keep the intentional debug logging path working
  identifierNamesGenerator: "hexadecimal",
  numbersToExpressions: true,
  renameGlobals: false, // must not rename chrome / addEventListener etc.
  selfDefending: true,
  simplify: true,
  splitStrings: true,
  splitStringsChunkLength: 8,
  stringArray: true,
  stringArrayCallsTransform: true,
  stringArrayEncoding: ["base64"],
  stringArrayThreshold: 0.9,
  transformObjectKeys: true,
  unicodeEscapeSequence: false
};

async function buildBundle({ out, inputs }) {
  const sources = [];
  for (const input of inputs) {
    sources.push(`/* ${input} */`);
    sources.push(await readFile(path.join(root, input), "utf8"));
  }
  const merged = sources.join("\n");
  const result = JavaScriptObfuscator.obfuscate(merged, obfuscatorOptions);
  await writeFile(path.join(dist, out), result.getObfuscatedCode(), "utf8");
  console.log(`  obfuscated ${out}  <- ${inputs.join(" + ")}`);
}

async function main() {
  if (existsSync(dist)) await rm(dist, { recursive: true });
  await mkdir(dist, { recursive: true });

  for (const bundle of bundles) await buildBundle(bundle);

  for (const file of copyAsIs) {
    await cp(path.join(root, file), path.join(dist, file));
    console.log(`  copied     ${file}`);
  }

  // labels.js is merged into content.js, so the shipped manifest must load only
  // content.js. Rewrite rather than copy so the two never drift.
  const manifest = JSON.parse(await readFile(path.join(root, "manifest.json"), "utf8"));
  for (const entry of manifest.content_scripts ?? []) {
    entry.js = entry.js.filter((file) => file !== "labels.js");
  }
  await writeFile(
    path.join(dist, "manifest.json"),
    JSON.stringify(manifest, null, 2) + "\n",
    "utf8"
  );
  console.log("  rewrote    manifest.json (labels.js merged into content.js)");
  for (const dir of copyDirs) {
    await cp(path.join(root, dir), path.join(dist, dir), { recursive: true });
    console.log(`  copied     ${dir}/`);
  }

  console.log(`\nDone. Load unpacked from: ${dist}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
