// src/overdrive/limits-env.mjs
// Pure: translate config.limits into a plan of env vars to apply.
// Keys prefixed `__unset_` request deletion of that env var by the caller.
export function limitEnv(limits = {}, env = {}) {
  const out = {};

  if (Number.isInteger(limits.thinkingBudget) && limits.thinkingBudget > 0) {
    out.MAX_THINKING_TOKENS = String(limits.thinkingBudget);
  }

  if (limits.context1m === true) {
    const with1m = (val, fallback) => {
      const base = val || fallback;
      return /\[1m\]$/i.test(base) ? base : base + "[1m]";
    };
    out.ANTHROPIC_DEFAULT_OPUS_MODEL = with1m(env.ANTHROPIC_DEFAULT_OPUS_MODEL, "claude-opus-4-8");
    out.ANTHROPIC_DEFAULT_SONNET_MODEL = with1m(env.ANTHROPIC_DEFAULT_SONNET_MODEL, "claude-sonnet-4-6");
    out.__unset_CLAUDE_CODE_DISABLE_1M_CONTEXT = true;
  }

  if (limits.concurrency === true) {
    out.LLMGOD_MAX_CONCURRENCY = "64";
  } else if (Number.isInteger(limits.concurrency) && limits.concurrency > 0) {
    out.LLMGOD_MAX_CONCURRENCY = String(limits.concurrency);
  }

  if (limits.modelAllowlist === true) {
    out.LLMGOD_ALLOW_ANY_MODEL = "1";
  }

  return out;
}
