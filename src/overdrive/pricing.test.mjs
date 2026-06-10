// src/overdrive/pricing.test.mjs
import { test, expect } from "bun:test";
import { normalizeModel, resolvePrice, computeCost } from "./pricing.mjs";

test("normalizeModel strips [1m] and provider prefix", () => {
  expect(normalizeModel("claude-opus-4-8[1m]")).toBe("claude-opus-4-8");
  expect(normalizeModel("anthropic/claude-sonnet-4-6")).toBe("claude-sonnet-4-6");
});

test("resolvePrice: override > table > null", () => {
  expect(resolvePrice("claude-opus-4-8")).toMatchObject({ input: 15 });
  expect(resolvePrice("mystery-model")).toBeNull();
  expect(resolvePrice("mystery-model", { "mystery-model": { input: 2, output: 4 } })).toMatchObject({ input: 2 });
});

test("computeCost: known model prices tokens", () => {
  const r = computeCost("claude-opus-4-8", { input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 0 });
  expect(r.priced).toBe(true);
  expect(r.usd).toBeCloseTo(15, 5);
});

test("computeCost: unknown model → unpriced, zero", () => {
  const r = computeCost("mystery", { input: 1000 });
  expect(r).toEqual({ usd: 0, priced: false });
});
