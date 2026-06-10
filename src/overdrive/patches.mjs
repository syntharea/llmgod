// src/overdrive/patches.mjs
// L3 regex patches for OVERDRIVE limits. Each is `optional` (skip on drift) and
// carries a `sentinel` so an absent construct never aborts patching.
// Both regexes are CONFIRMED against a real extracted cli.original.cjs
// (see fixtures/concurrency-slot.txt, fixtures/model-gate.txt) — exactly one
// match each, env-gated so they stay inert until the runtime env is set, and
// idempotent (the patched form does not re-match).
//
// Dropped after real-binary inspection:
//  - fan-out "4096": no numeric concurrency guard exists (all 4096s are
//    Buffer.alloc / file-read sizes; the fan-out cap is prose in a tool string).
//  - 1M tier gate: the gate is `if(disabled)return!1;return /[1m]/.test(model)`
//    with NO tier check — L1 (append [1m] to the model env) fully covers it.

const bound = "(globalThis.process?.env?.LLMGOD_MAX_CONCURRENCY|0||16)";

export const OVERDRIVE_PATCHES = [
  {
    // Parallel-agent slot cap. Real shape: function X(H){return Math.min(16,Math.max(2,H-2))}
    // Inert unless LLMGOD_MAX_CONCURRENCY is set (unset → |0||16 → original 16).
    name: "Concurrency: parallel-agent slot cap",
    sentinel: "Math.min(16,",
    optional: true,
    pattern: /Math\.min\(16,([^)]+)\)/g,
    replacer: (m, rest) => `Math.min(${bound},${rest})`,
  },
  {
    // Client-side model-id allowlist. Real shape:
    //   if($!=="claude-fable-5"&&$!=="claude-..."&&$!=="claude-opus-4-8")return!1;
    // Append an env guard so the gate is bypassed ONLY when the user opts in via
    // limits.modelAllowlist (→ LLMGOD_ALLOW_ANY_MODEL). Default: original behavior.
    name: "Model allowlist: strip client model-id gate",
    sentinel: '!=="claude-opus-4-',
    optional: true,
    pattern: /if\((([\w$]+)!=="claude-(?:[\w.-]+)"(?:&&\2!=="claude-[\w.-]+")*)\)return!1;/g,
    replacer: (m, cond) => `if((${cond})&&!globalThis.process?.env?.LLMGOD_ALLOW_ANY_MODEL)return!1;`,
  },
];
