// src/overdrive/patches.test.mjs
import { test, expect } from "bun:test";
import { readFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { OVERDRIVE_PATCHES } from "./patches.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fx = (name) => {
  const p = join(here, "fixtures", name);
  return existsSync(p) ? readFileSync(p, "utf8") : "";
};
const byName = (n) => OVERDRIVE_PATCHES.find((p) => p.name === n);

// Apply a single patch's pattern+replacer to a string (mirrors patch.mjs semantics).
function apply(patch, code) {
  if (patch.sentinel && !code.includes(patch.sentinel)) return { code, hit: false };
  let hit = false;
  const out = code.replace(patch.pattern, (...args) => { hit = true; return patch.replacer(...args); });
  return { code: out, hit };
}

test("each patch is well-formed and optional", () => {
  for (const p of OVERDRIVE_PATCHES) {
    expect(typeof p.name).toBe("string");
    expect(p.pattern instanceof RegExp).toBe(true);
    expect(typeof p.replacer).toBe("function");
    expect(p.optional).toBe(true); // OVERDRIVE patches never block startup
  }
});

test("only confirmed patches are shipped (no fan-out / 1M-L3)", () => {
  const names = OVERDRIVE_PATCHES.map((p) => p.name);
  expect(names).toContain("Concurrency: parallel-agent slot cap");
  expect(names).toContain("Model allowlist: strip client model-id gate");
  expect(names.length).toBe(2);
});

test("concurrency slot cap rewrites the real fixture, env-gated + idempotent", () => {
  const src = fx("concurrency-slot.txt");
  expect(src).toContain("Math.min(16,");
  const p = byName("Concurrency: parallel-agent slot cap");
  const { code, hit } = apply(p, src);
  expect(hit).toBe(true);
  expect(code).toContain("LLMGOD_MAX_CONCURRENCY");
  expect(code).toContain("Math.max(2,H-2)"); // inner expression preserved
  const again = apply(p, code);
  expect(again.code).toBe(code); // idempotent (sentinel gone → no-op)
});

test("model allowlist appends env guard on the real fixture, idempotent", () => {
  const src = fx("model-gate.txt");
  const p = byName("Model allowlist: strip client model-id gate");
  const { code, hit } = apply(p, src);
  expect(hit).toBe(true);
  expect(code).toContain("LLMGOD_ALLOW_ANY_MODEL");
  expect(code).toContain('claude-opus-4-8'); // original condition preserved
  const again = apply(p, code);
  expect(again.code).toBe(code); // patched form does not re-match
});

test("patch skips cleanly when sentinel absent", () => {
  const p = byName("Concurrency: parallel-agent slot cap");
  const { code, hit } = apply(p, "unrelated source with no anchor");
  expect(hit).toBe(false);
  expect(code).toBe("unrelated source with no anchor");
});
