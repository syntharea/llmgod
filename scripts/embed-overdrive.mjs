// scripts/embed-overdrive.mjs
// Regenerates the OVERDRIVE module block inside install.sh from the canonical
// repo sources in src/overdrive/. Run after editing any embedded module:
//   node scripts/embed-overdrive.mjs
// The drift guard test (test/install-sync.test.mjs) fails if install.sh is stale.
import { readFileSync, writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const MODULES = ["pricing.mjs", "metering.mjs", "probe.mjs", "statusline.mjs", "panel.mjs", "limits-env.mjs", "workflow-cli.mjs", "workflow-library.mjs"];

function block() {
  const out = ["# (regenerate with: node scripts/embed-overdrive.mjs)"];
  for (const f of MODULES) {
    const body = readFileSync(join(root, "src/overdrive", f), "utf8").replace(/\n+$/, "");
    const delim = "OVERDRIVE_" + f.replace(/[.-]/g, "_").toUpperCase() + "_EOF";
    out.push(`cat > "$LLMGOD_DIR/overdrive/${f}" << '${delim}'`);
    out.push(`// >>> OVERDRIVE ${f} >>>`);
    out.push(body);
    out.push(`// <<< OVERDRIVE ${f} <<<`);
    out.push(delim);
  }
  return out.join("\n");
}

const shPath = join(root, "install.sh");
const sh = readFileSync(shPath, "utf8");
const re = /(# >>> OVERDRIVE MODULES >>>\n)[\s\S]*?(\n# <<< OVERDRIVE MODULES <<<)/;
if (!re.test(sh)) { console.error("anchors not found in install.sh"); process.exit(1); }
writeFileSync(shPath, sh.replace(re, (m, a, b) => a + block() + b));
console.log(`embedded ${MODULES.length} modules into install.sh`);
