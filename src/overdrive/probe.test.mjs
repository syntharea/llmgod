// src/overdrive/probe.test.mjs
import { test, expect } from "bun:test";
import { readFileSync, mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { parseUsageFromSSE, installProbe } from "./probe.mjs";
import { newestMeter } from "./metering.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const sse = readFileSync(join(here, "fixtures", "messages-sse.txt"), "utf8");

test("parseUsageFromSSE extracts merged usage", () => {
  const u = parseUsageFromSSE(sse);
  expect(u.input_tokens).toBe(100);
  expect(u.cache_read_input_tokens).toBe(900);
  expect(u.output_tokens).toBe(42);
  expect(u.model).toBe("claude-opus-4-8");
});

test("installProbe wraps fetch and writes metering for /v1/messages", async () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(sse, { headers: { "content-type": "text/event-stream" } });
  try {
    const uninstall = installProbe({ }, dir, "test-session");
    await globalThis.fetch("https://api.anthropic.com/v1/messages", { method: "POST" });
    // allow the async tee to flush
    await new Promise((r) => setTimeout(r, 20));
    const m = newestMeter(dir);
    expect(m.tokens.input).toBe(100);
    expect(m.tokens.output).toBe(42);
    uninstall();
  } finally {
    globalThis.fetch = original;
  }
});

test("non-messages requests are passed through untouched", async () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response("ok");
  try {
    installProbe({}, dir, "s");
    const res = await globalThis.fetch("https://example.com/health");
    expect(await res.text()).toBe("ok");
  } finally {
    globalThis.fetch = original;
  }
});
