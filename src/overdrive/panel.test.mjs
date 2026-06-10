// src/overdrive/panel.test.mjs
import { test, expect } from "bun:test";
import { formatPanel } from "./panel.mjs";

const meter = {
  sessionId: "abc", model: "claude-opus-4-8",
  tokens: { input: 100, output: 50, cacheCreate: 10, cacheRead: 900 },
  cacheHitRate: 0.9, cost: { usd: 1.2345, priced: true },
};

test("no data → friendly message", () => {
  expect(formatPanel(null, {})).toContain("no metering data");
});

test("renders token split, hit rate, cost, billing-header status", () => {
  const out = formatPanel(meter, { baseURL: "https://api.deepseek.com" });
  expect(out).toContain("claude-opus-4-8");
  expect(out).toContain("cache read");
  expect(out).toContain("90%");
  expect(out).toContain("$1.2345");
  expect(out).toContain("billing header"); // third-party → reports disabled
});

test("unpriced model shows hint instead of $", () => {
  const out = formatPanel({ ...meter, cost: { usd: 0, priced: false } }, {});
  expect(out).toContain("set provider.json.pricing");
});
