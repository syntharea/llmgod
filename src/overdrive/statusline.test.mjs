// src/overdrive/statusline.test.mjs
import { test, expect } from "bun:test";
import { formatStatusline } from "./statusline.mjs";

const meter = { tokens: { input: 100, output: 50, cacheCreate: 0, cacheRead: 900 }, cacheHitRate: 0.9, cost: { usd: 1.27, priced: true } };

test("renders ctx, cost, cache when all present", () => {
  const line = formatStatusline({ cost: { total_cost_usd: 1.27 }, context: { used_pct: 38 } }, meter);
  expect(line).toContain("ctx 38%");
  expect(line).toContain("$1.27");
  expect(line).toContain("cache 90%");
});

test("drops missing fields, never prints NaN/0-noise", () => {
  const line = formatStatusline({}, null);
  expect(line).not.toContain("NaN");
  expect(line).toBe("");
});

test("falls back to meter cost when stdin lacks cost", () => {
  const line = formatStatusline({}, meter);
  expect(line).toContain("$1.27");
  expect(line).toContain("cache 90%");
});
