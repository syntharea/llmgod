// src/overdrive/metering.test.mjs
import { test, expect } from "bun:test";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { emptyMeter, accumulate, saveMeter, loadMeter, newestMeter } from "./metering.mjs";

test("accumulate folds usage and computes cache hit rate", () => {
  let m = emptyMeter("s1", "claude-opus-4-8");
  m = accumulate(m, { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 900 });
  expect(m.tokens.input).toBe(100);
  expect(m.tokens.cacheRead).toBe(900);
  // hit rate = 900 / (100 + 0 + 900) = 0.9
  expect(m.cacheHitRate).toBeCloseTo(0.9, 5);
  expect(m.cost.priced).toBe(true);
});

test("accumulate is additive across turns", () => {
  let m = emptyMeter("s2", "claude-opus-4-8");
  m = accumulate(m, { input_tokens: 10 });
  m = accumulate(m, { input_tokens: 5 });
  expect(m.tokens.input).toBe(15);
});

test("save/load round-trips; newestMeter returns last written", async () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  const a = accumulate(emptyMeter("sa", "claude-opus-4-8"), { input_tokens: 1 });
  saveMeter(dir, a);
  expect(loadMeter(dir, "sa").tokens.input).toBe(1);
  await Bun.sleep(10); // distinct mtime — real turns are seconds apart
  const b = accumulate(emptyMeter("sb", "claude-opus-4-8"), { input_tokens: 2 });
  saveMeter(dir, b);
  expect(newestMeter(dir).sessionId).toBe("sb");
});

test("loadMeter on missing file returns empty meter", () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  expect(loadMeter(dir, "nope").tokens.input).toBe(0);
});
