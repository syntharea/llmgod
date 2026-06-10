# OVERDRIVE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two coordinated capabilities to the llmgod patcher — *Limits Unchained* (toggle off Claude Code's client-side capability ceilings) and *Cost & Cache X-ray* (a read-only live instrument for spend and cache-hit rate).

**Architecture:** Three injection layers, "lift don't sink": L1 env injection + L2 runtime hooks in the `cli.cjs` wrapper (zero cli.js-drift risk), L3 regex patches in `patch.mjs` only for gates hardcoded in the minified cli.js. X-ray is a `globalThis.fetch` usage probe → atomic per-session metering file → statusLine headline + `llmgod xray` deep panel. Every L3 patch carries `sentinel`+`optional` (skip on drift, never fatal); all probe/panel code is try/caught (never perturbs the Claude process).

**Tech Stack:** Bun runtime, ESM `.mjs` modules, `bun:test` runner, bash (`install.sh` heredocs), regex patcher (`patch.mjs`).

**Spec:** `docs/superpowers/specs/2026-06-10-overdrive-limits-xray-design.md`

---

## File Structure

New repo source (canonical, TDD'd), mirrored into `install.sh` heredocs at the wiring tasks:

| File | Responsibility |
|------|----------------|
| `src/overdrive/pricing.mjs` | Price table + `computeCost` (pure) |
| `src/overdrive/metering.mjs` | `accumulate` (pure) + atomic load/save/newest (fs) |
| `src/overdrive/probe.mjs` | `installProbe(config, dir)` — wraps `globalThis.fetch`, parses `/v1/messages` SSE usage |
| `src/overdrive/statusline.mjs` | `formatStatusline(stdin, meter)` + stdin entrypoint (standalone process) |
| `src/overdrive/panel.mjs` | `formatPanel(meter, config)` + entrypoint (`llmgod xray`) |
| `src/overdrive/limits-env.mjs` | `limitEnv(limits, env)` — pure env-var plan for L1 limits |
| `src/overdrive/patches.mjs` | L3 patch objects (concurrency, modelAllowlist, 1M tier fallback) |
| `src/overdrive/*.test.mjs` | `bun:test` unit tests, colocated |
| `test/install-sync.test.mjs` | Drift guard: heredoc blocks in `install.sh` == `src/overdrive/*` |
| `install.sh` | Modified: write modules, extend `cli.cjs` (config/env/probe/argv/statusline), extend `patch.mjs` patches[] |

Runtime install layout: modules land in `~/.llmgod/overdrive/`; `cli.cjs` loads them from there.

---

## Phase 0 — Test harness

### Task 0: Bun test scaffold

**Files:**
- Create: `bunfig.toml`
- Create: `src/overdrive/.gitkeep`
- Create: `test/smoke.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
// test/smoke.test.mjs
import { test, expect } from "bun:test";

test("bun test runs", () => {
  expect(1 + 1).toBe(2);
});
```

- [ ] **Step 2: Run it to confirm the runner works**

Run: `bun test test/smoke.test.mjs`
Expected: PASS, `1 pass`.

- [ ] **Step 3: Add minimal bunfig**

```toml
# bunfig.toml
[test]
root = "."
```

- [ ] **Step 4: Commit**

```bash
git add bunfig.toml test/smoke.test.mjs src/overdrive/.gitkeep
git commit -m "test: add bun test scaffold for OVERDRIVE"
```

---

## Phase 1 — Module A: Limits Unchained

### Task 1: `limits-env.mjs` — L1 env plan (pure)

**Files:**
- Create: `src/overdrive/limits-env.mjs`
- Test: `src/overdrive/limits-env.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/overdrive/limits-env.test.mjs`
Expected: FAIL — `Cannot find module './limits-env.mjs'`.

- [ ] **Step 3: Write the implementation**

```js
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

  return out;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/overdrive/limits-env.test.mjs`
Expected: PASS, all cases.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/limits-env.mjs src/overdrive/limits-env.test.mjs
git commit -m "feat(limits): pure env plan for thinking/1m/concurrency toggles"
```

---

### Task 2: L3 patches — capture-driven regex for concurrency + model allowlist + 1M fallback

> These three gates are hardcoded in the minified `cli.js`. The regex MUST be derived from the real extracted source, not guessed. The test fixture (captured from `~/.llmgod/cli.original.cjs`) is the source of truth; the failing test drives the regex.

**Files:**
- Create: `src/overdrive/patches.mjs`
- Create: `src/overdrive/fixtures/` (captured snippets)
- Test: `src/overdrive/patches.test.mjs`

- [ ] **Step 1: Capture real snippets from the extracted binary**

Prereq: a patched install exists, so `~/.llmgod/cli.original.cjs` is present (run the installer once, or `node ~/.llmgod/repatch.mjs <native-bin>`).

Run (uses ripgrep directly — the shell here aliases `grep`/`find`, so call `rg` by full path):
```bash
RG=$(command -v rg)
"$RG" -o '.{40}(min\(16,|cpuCount|maxConcurren).{60}' ~/.llmgod/cli.original.cjs | head
"$RG" -o '.{20}4096.{40}' ~/.llmgod/cli.original.cjs | head
"$RG" -o '.{20}claude-opus-4-[0-9].{40}' ~/.llmgod/cli.original.cjs | head
"$RG" -o '.{20}(1m_context|context.?1m|DISABLE_1M).{40}' ~/.llmgod/cli.original.cjs | head
```
Paste each matched literal into `src/overdrive/fixtures/<name>.txt` verbatim (one construct per file: `concurrency-slot.txt`, `concurrency-fanout.txt`, `model-gate.txt`, `onem-gate.txt`). If a construct is genuinely absent on this version, create the fixture file empty — its test asserts "skips cleanly when sentinel absent".

- [ ] **Step 2: Write the failing test (drives the regex from the fixture)**

```js
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

test("each patch is well-formed", () => {
  for (const p of OVERDRIVE_PATCHES) {
    expect(typeof p.name).toBe("string");
    expect(p.pattern instanceof RegExp).toBe(true);
    expect(typeof p.replacer).toBe("function");
    expect(p.optional).toBe(true); // OVERDRIVE patches never block startup
  }
});

test("concurrency slot cap is raised and reads the env bound", () => {
  const src = fx("concurrency-slot.txt");
  if (!src) return; // construct absent on this version → patch is optional, skip
  const { code, hit } = apply(byName("Concurrency: parallel-agent slot cap"), src);
  expect(hit).toBe(true);
  expect(code).toContain("LLMGOD_MAX_CONCURRENCY");
  // idempotent: second application is a no-op
  const again = apply(byName("Concurrency: parallel-agent slot cap"), code);
  expect(again.code).toBe(code);
});

test("model-id gate is neutralized", () => {
  const src = fx("model-gate.txt");
  if (!src) return;
  const { hit } = apply(byName("Model allowlist: strip client model-id gate"), src);
  expect(hit).toBe(true);
});

test("patch skips cleanly when sentinel absent", () => {
  const p = byName("Concurrency: parallel-agent slot cap");
  const { code, hit } = apply(p, "unrelated source with no anchor");
  expect(hit).toBe(false);
  expect(code).toBe("unrelated source with no anchor");
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `bun test src/overdrive/patches.test.mjs`
Expected: FAIL — `Cannot find module './patches.mjs'`.

- [ ] **Step 4: Implement `patches.mjs`, iterating each regex until its fixture test passes**

```js
// src/overdrive/patches.mjs
// L3 regex patches for OVERDRIVE limits. Each is `optional` (skip on drift) and
// carries a `sentinel` so an absent construct never aborts patching.
// IMPORTANT: finalize each `pattern` against src/overdrive/fixtures/*.txt — the
// captured real cli.js snippet — not against a guessed shape.

const bound = "(globalThis.process?.env?.LLMGOD_MAX_CONCURRENCY|0||16)";

export const OVERDRIVE_PATCHES = [
  {
    // Parallel-agent slot cap, observed shape: Math.min(16, <cpu expr>)
    name: "Concurrency: parallel-agent slot cap",
    sentinel: "Math.min(16,",
    optional: true,
    pattern: /Math\.min\(16,([^)]+)\)/g,
    replacer: (m, rest) => `Math.min(${bound},${rest})`,
  },
  {
    // Fan-out item cap literal 4096 (Workflow/parallel). Replace with env bound, default kept high.
    name: "Concurrency: fan-out item cap",
    sentinel: "4096",
    optional: true,
    pattern: /([<>=]=?\s*)4096\b/g,
    replacer: (m, op) => `${op}(globalThis.process?.env?.LLMGOD_MAX_CONCURRENCY*64||4096)`,
  },
  {
    // Client-side model-id allowlist gate, observed shape:
    //   if(X!=="claude-opus-4-6"&&X!=="claude-sonnet-4-6"&&...)<reject>
    // Neutralize by forcing the condition false (gate passes for any id).
    name: "Model allowlist: strip client model-id gate",
    sentinel: '!=="claude-opus-4-',
    optional: true,
    pattern: /if\(([\w$]+)!=="claude-opus-4-[\s\S]{0,200}?\)(return!1;|return null;|throw[^;]+;)/g,
    replacer: (m, v, tail) => `if(!1)${tail}`,
  },
  {
    // 1M-context tier/disable gate fallback (L1 env is primary). Force the
    // "1M available" predicate true so [1m] picker variants are always offered.
    name: "1M context: force tier gate",
    sentinel: "DISABLE_1M_CONTEXT",
    optional: true,
    pattern: /process\.env\.CLAUDE_CODE_DISABLE_1M_CONTEXT/g,
    replacer: () => "(void 0)",
  },
];
```

> Iterate: run the test, inspect the fixture, adjust each `pattern`/`replacer` until the fixture-backed assertions pass and idempotency holds. If a construct's real shape differs from the skeleton above, **change the regex to match the captured fixture** — the fixture wins.

- [ ] **Step 5: Run to verify it passes**

Run: `bun test src/overdrive/patches.test.mjs`
Expected: PASS (constructs present pass; absent ones short-circuit via the `if (!src) return` guard).

- [ ] **Step 6: Commit**

```bash
git add src/overdrive/patches.mjs src/overdrive/patches.test.mjs src/overdrive/fixtures
git commit -m "feat(limits): L3 regex patches (concurrency, model allowlist, 1M gate)"
```

---

## Phase 2 — Module B: Cost & Cache X-ray

### Task 3: `pricing.mjs` — cost computation (pure)

**Files:**
- Create: `src/overdrive/pricing.mjs`
- Test: `src/overdrive/pricing.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/overdrive/pricing.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

```js
// src/overdrive/pricing.mjs
// USD per 1,000,000 tokens (standard <=200k tier). VERIFY against current public
// pricing at platform.claude.com/docs/about-claude/pricing before release.
export const PRICE_TABLE = {
  "claude-opus-4-8":   { input: 15, output: 75, cacheWrite1h: 30,  cacheWrite5m: 18.75, cacheRead: 1.5 },
  "claude-sonnet-4-6": { input: 3,  output: 15, cacheWrite1h: 6,   cacheWrite5m: 3.75,  cacheRead: 0.3 },
  "claude-haiku-4-5":  { input: 1,  output: 5,  cacheWrite1h: 2,   cacheWrite5m: 1.25,  cacheRead: 0.1 },
};

export function normalizeModel(model) {
  if (!model) return "";
  return String(model).replace(/\[1m\]$/i, "").replace(/^.*\//, "").trim();
}

export function resolvePrice(model, overrides = {}) {
  if (overrides && overrides[model]) return overrides[model];
  const norm = normalizeModel(model);
  if (overrides && overrides[norm]) return overrides[norm];
  return PRICE_TABLE[norm] || null;
}

export function computeCost(model, tokens = {}, overrides = {}) {
  const p = resolvePrice(model, overrides);
  if (!p) return { usd: 0, priced: false };
  const per = (n, rate) => ((Number(n) || 0) / 1e6) * (Number(rate) || 0);
  const usd =
    per(tokens.input, p.input) +
    per(tokens.output, p.output) +
    per(tokens.cacheCreate, p.cacheWrite1h ?? p.cacheWrite5m ?? p.input) +
    per(tokens.cacheRead, p.cacheRead);
  return { usd, priced: true };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/overdrive/pricing.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/pricing.mjs src/overdrive/pricing.test.mjs
git commit -m "feat(xray): pricing table + computeCost"
```

---

### Task 4: `metering.mjs` — accumulate (pure) + atomic fs

**Files:**
- Create: `src/overdrive/metering.mjs`
- Test: `src/overdrive/metering.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
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

test("save/load round-trips; newestMeter returns last written", () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  const a = accumulate(emptyMeter("sa", "claude-opus-4-8"), { input_tokens: 1 });
  saveMeter(dir, a);
  expect(loadMeter(dir, "sa").tokens.input).toBe(1);
  const b = accumulate(emptyMeter("sb", "claude-opus-4-8"), { input_tokens: 2 });
  saveMeter(dir, b);
  expect(newestMeter(dir).sessionId).toBe("sb");
});

test("loadMeter on missing file returns empty meter", () => {
  const dir = mkdtempSync(join(tmpdir(), "llmgod-"));
  expect(loadMeter(dir, "nope").tokens.input).toBe(0);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/overdrive/metering.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

```js
// src/overdrive/metering.mjs
import { readFileSync, writeFileSync, renameSync, mkdirSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { computeCost } from "./pricing.mjs";

export function emptyMeter(sessionId, model = "") {
  const now = Date.now();
  return {
    sessionId, model, startedAt: now, updatedAt: now, turns: 0,
    tokens: { input: 0, output: 0, cacheCreate: 0, cacheRead: 0 },
    cacheHitRate: 0, cost: { usd: 0, priced: false },
  };
}

// Pure: fold one API usage record into a meter, returning a new meter.
export function accumulate(meter, usage = {}, overrides = {}) {
  const t = meter.tokens;
  const tokens = {
    input: t.input + (usage.input_tokens || 0),
    output: t.output + (usage.output_tokens || 0),
    cacheCreate: t.cacheCreate + (usage.cache_creation_input_tokens || 0),
    cacheRead: t.cacheRead + (usage.cache_read_input_tokens || 0),
  };
  const cacheable = tokens.input + tokens.cacheCreate + tokens.cacheRead;
  const cacheHitRate = cacheable > 0 ? tokens.cacheRead / cacheable : 0;
  const model = usage.model || meter.model;
  return {
    ...meter, model, updatedAt: Date.now(),
    turns: meter.turns + (usage.__turn ? 1 : 0),
    tokens, cacheHitRate, cost: computeCost(model, tokens, overrides),
  };
}

const dirFor = (dir) => join(dir, "metering");
export const meterPath = (dir, id) => join(dirFor(dir), `session-${id}.json`);

export function saveMeter(dir, meter) {
  mkdirSync(dirFor(dir), { recursive: true });
  const p = meterPath(dir, meter.sessionId);
  const tmp = p + ".tmp";
  writeFileSync(tmp, JSON.stringify(meter));
  renameSync(tmp, p);
}

export function loadMeter(dir, id, model = "") {
  try { return JSON.parse(readFileSync(meterPath(dir, id), "utf8")); }
  catch { return emptyMeter(id, model); }
}

export function newestMeter(dir) {
  try {
    const files = readdirSync(dirFor(dir)).filter((f) => f.startsWith("session-") && f.endsWith(".json"));
    if (!files.length) return null;
    const newest = files
      .map((f) => ({ f, m: statSync(join(dirFor(dir), f)).mtimeMs }))
      .sort((a, b) => b.m - a.m)[0].f;
    return JSON.parse(readFileSync(join(dirFor(dir), newest), "utf8"));
  } catch { return null; }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/overdrive/metering.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/metering.mjs src/overdrive/metering.test.mjs
git commit -m "feat(xray): metering accumulate + atomic per-session store"
```

---

### Task 5: `probe.mjs` — globalThis.fetch usage probe

**Files:**
- Create: `src/overdrive/probe.mjs`
- Create: `src/overdrive/fixtures/messages-sse.txt` (captured streaming body)
- Test: `src/overdrive/probe.test.mjs`

- [ ] **Step 1: Capture a real `/v1/messages` SSE body**

Save a representative streamed response body to `src/overdrive/fixtures/messages-sse.txt`. It must contain a `message_start` event with `usage` (input/cache tokens) and a final `message_delta` with `usage.output_tokens`. Minimal valid fixture:

```
event: message_start
data: {"type":"message_start","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"output_tokens":1}}}

event: message_delta
data: {"type":"message_delta","usage":{"output_tokens":42}}

event: message_stop
data: {"type":"message_stop"}
```

- [ ] **Step 2: Write the failing test**

```js
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
```

- [ ] **Step 3: Run to verify it fails**

Run: `bun test src/overdrive/probe.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 4: Write the implementation**

```js
// src/overdrive/probe.mjs
import { loadMeter, saveMeter, accumulate } from "./metering.mjs";

// Pure: pull merged usage out of an SSE message stream body.
export function parseUsageFromSSE(text) {
  const usage = { model: "" };
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (!s.startsWith("data:")) continue;
    let obj;
    try { obj = JSON.parse(s.slice(5).trim()); } catch { continue; }
    if (obj.type === "message_start" && obj.message) {
      usage.model = obj.message.model || usage.model;
      Object.assign(usage, obj.message.usage || {});
    } else if (obj.type === "message_delta" && obj.usage) {
      Object.assign(usage, obj.usage); // output_tokens lands here
    }
  }
  return usage;
}

const isMessagesUrl = (u) => typeof u === "string" ? /\/v1\/messages\b/.test(u)
  : !!(u && u.url && /\/v1\/messages\b/.test(u.url));

// Installs a globalThis.fetch wrapper. Returns an uninstall fn.
// Fully fault-isolated: any failure falls back to the original fetch.
export function installProbe(config = {}, dir, sessionId) {
  const original = globalThis.fetch;
  const overrides = config.pricing || {};
  globalThis.fetch = async function (input, init) {
    const res = await original(input, init);
    try {
      const url = typeof input === "string" ? input : input?.url;
      if (isMessagesUrl(url) && res && res.body) {
        const clone = res.clone();
        clone.text().then((body) => {
          try {
            const usage = parseUsageFromSSE(body);
            usage.__turn = true;
            const meter = accumulate(loadMeter(dir, sessionId, usage.model), usage, overrides);
            saveMeter(dir, meter);
          } catch { /* metering is best-effort */ }
        }).catch(() => {});
      }
    } catch { /* never perturb the request */ }
    return res;
  };
  return function uninstall() { globalThis.fetch = original; };
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bun test src/overdrive/probe.test.mjs`
Expected: PASS, all three.

- [ ] **Step 6: Commit**

```bash
git add src/overdrive/probe.mjs src/overdrive/probe.test.mjs src/overdrive/fixtures/messages-sse.txt
git commit -m "feat(xray): globalThis.fetch usage probe + SSE parser"
```

---

### Task 6: `statusline.mjs` — one-line headline

**Files:**
- Create: `src/overdrive/statusline.mjs`
- Test: `src/overdrive/statusline.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/overdrive/statusline.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

```js
// src/overdrive/statusline.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";

// stdin: Claude Code statusLine payload. Field names are defensive — confirm
// against code.claude.com/docs/en/statusline; unknown fields are simply dropped.
export function formatStatusline(stdin = {}, meter = null) {
  const parts = [];

  const ctx = stdin?.context?.used_pct ?? stdin?.context_percent;
  if (typeof ctx === "number" && isFinite(ctx)) parts.push(`ctx ${Math.round(ctx)}%`);

  const usd = stdin?.cost?.total_cost_usd ?? (meter?.cost?.priced ? meter.cost.usd : null);
  if (typeof usd === "number" && isFinite(usd)) parts.push(`$${usd.toFixed(2)}`);

  if (meter) {
    const t = meter.tokens;
    if (t && (t.cacheRead + t.input + t.cacheCreate) > 0)
      parts.push(`cache ${Math.round((meter.cacheHitRate || 0) * 100)}%`);
  }

  return parts.join(" · ");
}

async function readStdin() {
  let data = "";
  for await (const chunk of process.stdin) data += chunk;
  try { return JSON.parse(data); } catch { return {}; }
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    const stdin = await readStdin();
    process.stdout.write(formatStatusline(stdin, newestMeter(dir)));
  } catch { /* a broken statusline must never break the prompt */ }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/overdrive/statusline.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/statusline.mjs src/overdrive/statusline.test.mjs
git commit -m "feat(xray): statusLine one-line headline renderer"
```

---

### Task 7: `panel.mjs` — `llmgod xray` deep panel

**Files:**
- Create: `src/overdrive/panel.mjs`
- Test: `src/overdrive/panel.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test src/overdrive/panel.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the implementation**

```js
// src/overdrive/panel.mjs
import { newestMeter } from "./metering.mjs";
import { homedir } from "os";
import { join } from "path";
import { readFileSync } from "fs";

const n = (x) => (Number(x) || 0).toLocaleString();

export function formatPanel(meter, config = {}) {
  if (!meter) return "llmgod xray: no metering data yet — run a turn first.";
  const t = meter.tokens;
  const thirdParty = !!(config.baseURL && !/anthropic\.com/i.test(config.baseURL));
  const lines = [
    `Session ${meter.sessionId}  ·  ${meter.model || "unknown"}`,
    ``,
    `  input        ${n(t.input)}`,
    `  output       ${n(t.output)}`,
    `  cache write  ${n(t.cacheCreate)}`,
    `  cache read   ${n(t.cacheRead)}`,
    `  cache hit    ${Math.round((meter.cacheHitRate || 0) * 100)}%`,
    ``,
    meter.cost.priced
      ? `  cost         $${meter.cost.usd.toFixed(4)}`
      : `  cost         (no price for model — set provider.json.pricing)`,
    `  billing header ${thirdParty ? "disabled (third-party cache fix active)" : "enabled (Anthropic)"}`,
  ];
  return lines.join("\n");
}

if (import.meta.main) {
  try {
    const dir = join(homedir(), ".llmgod");
    let config = {};
    try { config = JSON.parse(readFileSync(join(dir, "provider.json"), "utf8")); } catch {}
    process.stdout.write(formatPanel(newestMeter(dir), config) + "\n");
  } catch (e) {
    process.stdout.write("llmgod xray: unavailable\n");
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun test src/overdrive/panel.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/panel.mjs src/overdrive/panel.test.mjs
git commit -m "feat(xray): llmgod xray deep panel renderer"
```

---

## Phase 3 — install.sh wiring + drift guard

### Task 8: Embed modules + wire `cli.cjs` (config, limits env, probe, argv, statusLine)

**Files:**
- Modify: `install.sh` — add heredocs writing `src/overdrive/*.mjs` into `$LLMGOD_DIR/overdrive/`; extend the `cli.cjs` heredoc (config read `install.sh:847-852`, env block `install.sh:860-891`, require `install.sh:902`).
- Test: `test/install-sync.test.mjs` (drift guard)

- [ ] **Step 1: Write the drift-guard failing test**

```js
// test/install-sync.test.mjs
import { test, expect } from "bun:test";
import { readFileSync } from "fs";

const sh = readFileSync("install.sh", "utf8");
const mod = (name) => readFileSync(`src/overdrive/${name}`, "utf8").trim();

// Each module is embedded between exact marker lines in install.sh.
function embedded(name) {
  const re = new RegExp(`# >>> OVERDRIVE ${name} >>>\\n([\\s\\S]*?)\\n# <<< OVERDRIVE ${name} <<<`);
  const m = sh.match(re);
  return m ? m[1].trim() : null;
}

for (const f of ["pricing.mjs", "metering.mjs", "probe.mjs", "statusline.mjs", "panel.mjs", "limits-env.mjs", "patches.mjs"]) {
  test(`install.sh embeds current ${f}`, () => {
    expect(embedded(f)).toBe(mod(f));
  });
}

test("cli.cjs applies limits env and installs probe before require", () => {
  expect(sh).toContain("limitEnv(");
  expect(sh).toContain("installProbe(");
  expect(sh).toContain("argv[2] === 'xray'");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test test/install-sync.test.mjs`
Expected: FAIL — markers/embeds absent.

- [ ] **Step 3: Add module-writing heredocs to install.sh**

After the existing `repatch.mjs` block (around `install.sh:799`), add a block that creates `$LLMGOD_DIR/overdrive/` and writes each module. Wrap each embedded copy in the exact markers the drift test expects. Pattern for one module (repeat for all 7):

```bash
mkdir -p "$LLMGOD_DIR/overdrive"
cat > "$LLMGOD_DIR/overdrive/pricing.mjs" << 'OVERDRIVE_PRICING_EOF'
# >>> OVERDRIVE pricing.mjs >>>
<verbatim contents of src/overdrive/pricing.mjs>
# <<< OVERDRIVE pricing.mjs <<<
OVERDRIVE_PRICING_EOF
```

> The marker comment lines live *inside* the heredoc so they ship to disk too; the drift test strips them via the trim+regex. Keep the body byte-identical to the repo file. (The leading `# ...` marker lines are JS comments only if the module starts with `//` — keep them on their own lines; they are valid JS line comments since `#` is not, so instead place markers as `// >>> OVERDRIVE ...` and update the test regex to `// >>>`. Use `//` markers to stay valid JS.)

> **Correction:** use `// >>> OVERDRIVE <name> >>>` / `// <<< OVERDRIVE <name> <<<` (JS line comments) as the markers, and update the drift-test regex in Step 1 to match `// >>>`/`// <<<`. This keeps the shipped `.mjs` syntactically valid.

- [ ] **Step 4: Extend the `cli.cjs` heredoc**

Insert near the top of the runtime section (after `const llmgodDir = ...`, ~`install.sh:810`) the `xray` argv dispatch (runs before any env/require):

```js
// OVERDRIVE: llmgod xray deep panel — handle before anything else.
if (process.argv[2] === 'xray') {
  const { spawnSync } = require('child_process');
  spawnSync(process.execPath, [join(llmgodDir, 'overdrive', 'panel.mjs'), ...process.argv.slice(3)], { stdio: 'inherit' });
  process.exit(0);
}
```

Replace the final `require('./cli.original.cjs');` (`install.sh:902`) with an async IIFE that applies the limits env plan, then installs the probe, then requires the CLI (single async region so the `await import`s are legal in this `.cjs` file):

```js
// OVERDRIVE: apply Limits Unchained env plan + install X-ray probe, then start the CLI.
(async () => {
  try {
    const { limitEnv } = await import(join(llmgodDir, 'overdrive', 'limits-env.mjs'));
    const plan = limitEnv(config.limits || {}, process.env);
    for (const [k, v] of Object.entries(plan)) {
      if (k.startsWith('__unset_')) { delete process.env[k.slice(8)]; continue; }
      if (process.env[k] == null) process.env[k] = v;
    }
  } catch {}
  try {
    if ((config.xray?.enabled ?? true)) {
      const sid = process.env.LLMGOD_SESSION || (process.env.LLMGOD_SESSION = require('crypto').randomUUID());
      const { installProbe } = await import(join(llmgodDir, 'overdrive', 'probe.mjs'));
      installProbe(config, llmgodDir, sid);
    }
  } catch {}
  require('./cli.original.cjs');
})();
```

- [ ] **Step 5: Add idempotent statusLine registration**

In the `cli.cjs` runtime section (before the async IIFE, guarded by `config.xray?.statusLine !== false`), register the statusline only when the user has none:

```js
// OVERDRIVE: register X-ray statusLine if the user has none (never clobber).
try {
  if ((config.xray?.statusLine ?? true)) {
    const settingsPath = join(homedir(), '.claude', 'settings.json');
    let s = {};
    try { s = JSON.parse(readFileSync(settingsPath, 'utf8')); } catch {}
    if (!s.statusLine) {
      s.statusLine = { type: 'command', command: `${process.execPath} ${join(llmgodDir, 'overdrive', 'statusline.mjs')}` };
      mkdirSync(join(homedir(), '.claude'), { recursive: true });
      writeFileSync(settingsPath, JSON.stringify(s, null, 2) + '\n');
    }
  }
} catch {}
```

> `homedir`, `readFileSync`, `writeFileSync`, `mkdirSync` are already imported at the top of `cli.cjs` (`install.sh:805-807`). Confirm `homedir` is in the destructured `require('os')`; add it if missing.

- [ ] **Step 6: Run the drift guard to verify it passes**

Run: `bun test test/install-sync.test.mjs`
Expected: PASS (embeds match; cli.cjs contains `limitEnv(`, `installProbe(`, `argv[2] === 'xray'`).

- [ ] **Step 7: Syntax-check the generated wrapper (safe, no eval)**

Install into a throwaway HOME, then use `node --check` (parses without executing — no `new Function`/`eval`):
```bash
tmp=$(mktemp -d)
HOME="$tmp" bash install.sh --uninstall >/dev/null 2>&1 || true   # no-op if unsupported
HOME="$tmp" bash install.sh >/dev/null 2>&1 || true
node --check "$tmp/.llmgod/cli.cjs" && echo "cli.cjs syntax OK"
for m in "$tmp"/.llmgod/overdrive/*.mjs; do node --check "$m" && echo "OK $m"; done
```
Expected: `cli.cjs syntax OK` and an `OK` line per module. Any syntax error means an embed went wrong — fix and re-run.

- [ ] **Step 8: Commit**

```bash
git add install.sh test/install-sync.test.mjs
git commit -m "feat(install): wire OVERDRIVE modules into cli.cjs (limits env, probe, xray, statusline)"
```

---

### Task 9: Extend `patch.mjs` with the L3 patches

**Files:**
- Modify: `install.sh` — the `patch.mjs` heredoc `patches[]` array (`install.sh:924+`).

- [ ] **Step 1: Add the drift assertion (extends Task 8's test)**

Append to `test/install-sync.test.mjs`:

```js
test("patch.mjs includes OVERDRIVE L3 patch names", () => {
  for (const name of [
    "Concurrency: parallel-agent slot cap",
    "Concurrency: fan-out item cap",
    "Model allowlist: strip client model-id gate",
    "1M context: force tier gate",
  ]) expect(sh).toContain(name);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test test/install-sync.test.mjs`
Expected: FAIL — patch names absent.

- [ ] **Step 3: Inline the patch objects into the `patches[]` array**

In the `patch.mjs` heredoc, before the closing `];` of `const patches = [ ... ]`, paste the four objects from `src/overdrive/patches.mjs` (the `OVERDRIVE_PATCHES` entries). `patch.mjs` runs at patch time (no provider.json in scope), so the patches apply *structurally* but stay inert until the matching limit is enabled at runtime: concurrency patches read `LLMGOD_MAX_CONCURRENCY` (unset → original default preserved by the `|0||16` / `*64||4096` fallbacks), model/1M patches are benign when their env/flag isn't set. Confirm each object carries `optional: true` and a `sentinel`.

> Keep `src/overdrive/patches.mjs` canonical; the drift guard (Task 8) ensures the embedded bodies match. Because these are pasted inline (not embedded via markers), this test only checks the names are present — the regex bodies are reviewed by the Task 2 fixture tests.

- [ ] **Step 4: Verify the patcher still runs clean against a real binary**

Run: `node ~/.llmgod/repatch.mjs "$(ls -t ~/.local/share/claude/versions/* 2>/dev/null | head -1)"`
Expected: `[llmgod] re-patched to <version>` with no thrown errors; absent constructs report as skipped, not fatal.

- [ ] **Step 5: Run full test suite**

Run: `bun test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add install.sh test/install-sync.test.mjs
git commit -m "feat(patch): add OVERDRIVE L3 patches to patch.mjs patches[]"
```

---

## Phase 4 — Integration verification & docs

### Task 10: End-to-end verification + README

**Files:**
- Modify: `README.md`, `README_ZH.md`, `README_JP.md` — add OVERDRIVE to the feature tables.
- Create: `test/regression-config-absent.test.mjs`

- [ ] **Step 1: Regression test — absent config = no behavior change**

```js
// test/regression-config-absent.test.mjs
import { test, expect } from "bun:test";
import { limitEnv } from "../src/overdrive/limits-env.mjs";

test("no limits config produces zero env mutations", () => {
  expect(limitEnv({}, {})).toEqual({});
  expect(limitEnv(undefined, {})).toEqual({});
});
```

Run: `bun test test/regression-config-absent.test.mjs` → Expected: PASS.

- [ ] **Step 2: Manual E2E checklist (run against a real install)**

Record results in the PR description:
1. `provider.json` `limits.thinkingBudget=32000` → start `llmgod`, trigger extended thinking, confirm a larger thinking budget (no cap error).
2. `limits.context1m=true` against a 1M-capable endpoint → confirm a >200k-token context is accepted; against a non-capable plan → confirm the documented long-context error (proves opt-in default-off is correct).
3. Run any turn → statusLine shows `ctx … · $… · cache …%`; `llmgod xray` panel numbers match `/cost`.
4. `limits.concurrency=64` → dispatch many parallel agents, confirm >default concurrency, no OOM.
5. Remove all OVERDRIVE keys → behavior identical to current build (regression).

- [ ] **Step 3: Update README feature tables**

Add to "Feature Unlocks" and a new "Observability" row in `README.md` (mirror into `README_ZH.md`, `README_JP.md`):

```markdown
| **Limits Unchained** | Toggle off client-side ceilings: 1M context, thinking budget, agent concurrency, model allowlist (`provider.json.limits`) |
| **Cost & Cache X-ray** | Live statusLine HUD (spend, cache-hit %) + `llmgod xray` deep panel; verifies the cache fixes actually work |
```

- [ ] **Step 4: Commit**

```bash
git add README.md README_ZH.md README_JP.md test/regression-config-absent.test.mjs
git commit -m "docs: document OVERDRIVE; add config-absent regression test"
```

---

## Self-Review (completed inline)

- **Spec coverage:** §4.1 thinkingBudget→Task1; §4.2 context1m→Task1(L1)+Task2(L3); §4.3 concurrency→Task1(env)+Task2(L3); §4.4 modelAllowlist→Task2; §5.1 probe→Task5; §5.2 metering schema→Task4; §5.3 statusLine→Task6; §5.4 pricing→Task3; §5.6 panel→Task7; §5.7 statusLine registration→Task8; §6 config→Tasks1/8; §7 fault tolerance→`optional`/try-catch throughout; §8 testing→every task is TDD + Task9 patcher run + Task10 E2E. All sections covered.
- **Placeholder scan:** L3 regexes are explicitly capture-driven (fixture is source of truth), not blank TODOs. Pricing numbers carry a verify-before-release note (real values to confirm, not blanks).
- **Type consistency:** `emptyMeter`/`accumulate`/`saveMeter`/`loadMeter`/`newestMeter`/`meterPath`, `computeCost`/`resolvePrice`/`normalizeModel`/`PRICE_TABLE`, `limitEnv`, `installProbe`/`parseUsageFromSSE`, `formatStatusline`, `formatPanel`, `OVERDRIVE_PATCHES` — names used consistently across tasks and the install.sh wiring.

## Out of scope (deferred)
- statusLine burn-rate field (`↑k/min`) — needs time-windowed deltas; v1 ships ctx·$·cache%.
- Persistent JSONL metrics export, true session-id correlation, in-CLI `/xray` slash command.

---

## Implementation Status (2026-06-10)

**Done & verified in-repo (36 `bun test` green, `node --check` + `bash -n` clean):**
- Tasks 0,1,3,4,5,6,7 — all 7 logic modules under `src/overdrive/` with colocated tests.
- Task 8 — runtime wiring into `install.sh`: 6 modules embedded via `scripts/embed-overdrive.mjs`
  (byte-identical, drift-guarded by `test/install-sync.test.mjs`); `cli.cjs` gains the
  `llmgod xray` argv dispatch, the L1 limits env plan, the L2 `globalThis.fetch` probe, and
  idempotent statusLine registration. Verified by extracting the `cli.cjs` heredoc body and the
  6 embedded modules and running `node --check` on each, plus `bash -n install.sh`.
- Task 10 (partial) — README.md documents Limits Unchained, Cost & Cache X-ray, and the
  `provider.json` OVERDRIVE keys.

**Deferred — requires a real `~/.llmgod/cli.original.cjs` to do safely:**
- ~~Task 2 fixtures / Task 9 L3 wiring~~ — **DONE & verified 2026-06-10** against the real
  `~/.llmgod/cli.original.cjs`. Real-binary inspection corrected the guesses: dropped the
  fan-out `4096` patch (no numeric guard — all `4096`s are buffer sizes) and the 1M tier-gate
  patch (gate has no tier check; L1 `[1m]` env suffices). The two surviving patches
  (concurrency slot cap, model allowlist) are env-gated, idempotent, and each hit exactly once.
  End-to-end verified: extracted patch.mjs from install.sh, dry-ran it on a copy of the real
  binary → both report `✅ … (1 replacement)`.
- Live E2E on an actual running claude (1M acceptance, statusLine render, `llmgod xray` vs
  `/cost`, concurrency-without-OOM) — still pending an install.
- README_ZH.md / README_JP.md mirroring of the OVERDRIVE entries.

**Net effect:** all four ceilings + X-ray are implemented, wired into install.sh, and verified
(38 `bun test` green; patcher dry-run clean on the real binary). Remaining: perform the install
and observe behavior on a live session.
