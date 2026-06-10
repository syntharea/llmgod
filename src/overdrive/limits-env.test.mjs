// src/overdrive/limits-env.test.mjs
import { test, expect } from "bun:test";
import { limitEnv } from "./limits-env.mjs";

test("absent limits → no env", () => {
  expect(limitEnv({}, {})).toEqual({});
});

test("thinkingBudget sets MAX_THINKING_TOKENS", () => {
  expect(limitEnv({ thinkingBudget: 32000 }, {})).toEqual({ MAX_THINKING_TOKENS: "32000" });
});

test("thinkingBudget 0/non-int ignored", () => {
  expect(limitEnv({ thinkingBudget: 0 }, {})).toEqual({});
  expect(limitEnv({ thinkingBudget: 1.5 }, {})).toEqual({});
});

test("context1m appends [1m] and requests unset of disable flag", () => {
  const out = limitEnv({ context1m: true }, {});
  expect(out.ANTHROPIC_DEFAULT_OPUS_MODEL).toBe("claude-opus-4-8[1m]");
  expect(out.ANTHROPIC_DEFAULT_SONNET_MODEL).toBe("claude-sonnet-4-6[1m]");
  expect(out.__unset_CLAUDE_CODE_DISABLE_1M_CONTEXT).toBe(true);
});

test("context1m does not double-append [1m]", () => {
  const out = limitEnv({ context1m: true }, { ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-4-8[1m]" });
  expect(out.ANTHROPIC_DEFAULT_OPUS_MODEL).toBe("claude-opus-4-8[1m]");
});

test("concurrency true → default bound 64; number → explicit", () => {
  expect(limitEnv({ concurrency: true }, {}).LLMGOD_MAX_CONCURRENCY).toBe("64");
  expect(limitEnv({ concurrency: 128 }, {}).LLMGOD_MAX_CONCURRENCY).toBe("128");
});

test("modelAllowlist true → LLMGOD_ALLOW_ANY_MODEL", () => {
  expect(limitEnv({ modelAllowlist: true }, {}).LLMGOD_ALLOW_ANY_MODEL).toBe("1");
  expect(limitEnv({ modelAllowlist: false }, {}).LLMGOD_ALLOW_ANY_MODEL).toBeUndefined();
});
