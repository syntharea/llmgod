// test/install-sync.test.mjs
// Drift guard: the OVERDRIVE module bodies embedded in install.sh must match the
// canonical sources in src/overdrive/. Regenerate with: node scripts/embed-overdrive.mjs
import { test, expect } from "bun:test";
import { readFileSync } from "fs";

const sh = readFileSync("install.sh", "utf8");
const mod = (name) => readFileSync(`src/overdrive/${name}`, "utf8").trim();

function embedded(name) {
  const re = new RegExp(`// >>> OVERDRIVE ${name} >>>\\n([\\s\\S]*?)\\n// <<< OVERDRIVE ${name} <<<`);
  const m = sh.match(re);
  return m ? m[1].trim() : null;
}

for (const f of ["pricing.mjs", "metering.mjs", "probe.mjs", "statusline.mjs", "panel.mjs", "limits-env.mjs"]) {
  test(`install.sh embeds current ${f}`, () => {
    expect(embedded(f)).toBe(mod(f));
  });
}

test("cli.cjs wires limits env, probe, and xray dispatch", () => {
  expect(sh).toContain("limitEnv(");
  expect(sh).toContain("installProbe(");
  expect(sh).toContain("process.argv[2] === 'xray'");
  expect(sh).toContain("pathToFileURL"); // cross-platform dynamic import
});

test("patch.mjs includes the confirmed OVERDRIVE L3 patches", () => {
  expect(sh).toContain("Concurrency: parallel-agent slot cap");
  expect(sh).toContain("Model allowlist: strip client model-id gate");
  expect(sh).toContain("LLMGOD_ALLOW_ANY_MODEL");
});
