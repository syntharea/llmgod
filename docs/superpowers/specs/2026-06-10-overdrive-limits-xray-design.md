# OVERDRIVE — Limits Unchained + Cost & Cache X-ray

> Design spec · 2026-06-10 · branch `feature/overdrive`
> Status: **approved for planning** (brainstorming complete)

## 1. Motivation

`llmgod` (Let's LLM) is a runtime patcher for Claude Code: 28 regex/env patches that
unlock "god mode" on the official binary. Today's patches cover hidden commands,
GrowthBook flags, Agent Teams, Computer Use, Auto-mode, security-refusal removal,
green theme, and prompt-cache reliability fixes.

Two high-leverage axes are **not yet covered**, and both are client-side reachable:

- **Limits Unchained** — the official binary enforces client-side *capability ceilings*
  (1M-context tier gate, extended-thinking budget cap, subagent/fan-out concurrency
  caps, model-id allowlist). Removing them turns llmgod from "more features" into
  "more raw power".
- **Cost & Cache X-ray** — the unlocks above push token usage up, yet the *cost* and
  the *cache-hit reality* stay invisible. X-ray is a read-only instrument that surfaces
  live spend, cache-hit rate, and 1h-cache savings — which also **independently
  verifies** that the existing cache patches actually work.

They ship together as one feature bundle, **OVERDRIVE**, because A creates the cost and
B measures it. B is the dashboard for A *and* for llmgod's existing cache fixes.

## 2. Goals / Non-goals

**Goals**
- Each of the 4 ceilings is independently toggleable via `~/.llmgod/provider.json`.
- Prefer env/runtime injection over brittle minified-cli.js regex ("lift, don't sink").
- X-ray is **zero-impact on the main flow**: a read-only side channel. If metering fails,
  Claude Code runs exactly as before.
- X-ray surfaces a one-line statusLine headline + an on-demand `llmgod xray` deep panel.
- Accurate cache metrics (real `cache_read` / `cache_creation`) via a usage probe.
- Honest behavior on third-party endpoints: client stops *refusing*; whether a limit
  truly takes effect depends on the endpoint, and the spec says so to the user.

**Non-goals (YAGNI)**
- No persistent JSONL metrics export / graphing (explicitly deferred by the user).
- No new in-CLI slash command (panel ships as a sibling `llmgod xray` subcommand —
  avoids patching command registration).
- No multi-session metering correlation in v1 (newest-active-session model; see §5.5).
- No pricing for arbitrary unknown models beyond a built-in table + user override.

## 3. Architecture — three injection layers

Ordered by resistance to cli.js minification drift; **always pick the highest layer that works**.

| Layer | Where | Carries | Drift risk |
|-------|-------|---------|-----------|
| **L1 env injection** | `cli.cjs` wrapper, before `require('./cli.original.cjs')` | limits controllable by env var | none |
| **L2 runtime hook** | `cli.cjs` wrapper, before require | fetch usage-probe; `argv[2]==='xray'` dispatch; idempotent statusLine registration | none (never touches cli.js) |
| **L3 regex patch** | `patch.mjs` `patches[]` | gates hardcoded in cli.js (concurrency caps, model allowlist, 1M tier gate) | version-tracked; each carries `sentinel` + `optional:true` |

**Injection surfaces already exist** (verified in `install.sh`):
- `cli.cjs` reads `provider.json` → `config` (L847–852) and sets `process.env.*` (L860–891),
  then `require('./cli.original.cjs')` (L902). New keys `limits` / `pricing` / `xray`
  merge into `defaultConfig` and are consumed here.
- `patch.mjs` `patches[]` (L924+) is an array of `{name, pattern, replacer, sentinel?,
  optional?, unique?, validate?}`. New ceilings that need L3 append here, following the
  same contract.

**Fault-tolerance baseline (whole bundle)**
- Every L3 patch carries a `sentinel`; if the anchor is absent on a given Claude version,
  the patch is **skipped, not fatal** (`optional:true`). Missing one ceiling degrades that
  one feature; startup still succeeds.
- All L2 probe/panel code is wrapped in `try/catch` with silent fallback. A metering write
  failure hides X-ray output but never perturbs the Claude process.

## 4. Module A — Limits Unchained

Four ceilings, each gated by `provider.json.limits.<key>` (all default **off** — opt-in power).

### 4.1 `thinkingBudget` — pure L1 ✅ cleanest
- Mechanism: set `process.env.MAX_THINKING_TOKENS` from `config.limits.thinkingBudget`
  (integer). `MAX_THINKING_TOKENS` is a real Claude Code env var that forces the extended-
  thinking budget. No cli.js patch at all.
- Note: `MAX_THINKING_TOKENS` only bites when extended thinking is active
  (`alwaysThinkingEnabled: true` in the user's settings.json, or a manual trigger). Turning
  thinking *on* is out of scope — the user's settings.json stays authoritative; OVERDRIVE
  only raises the budget cap.

### 4.2 `context1m` — L1 primary + L3 fallback
- L1: when `true`, ensure the model id carries the `[1m]` suffix. The wrapper appends `[1m]`
  to `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` (and to `config.model`
  if set), and ensures `CLAUDE_CODE_DISABLE_1M_CONTEXT` is **not** forced to `1`. Optionally
  inject `anthropic-beta: context-1m-2025-08-07` via `ANTHROPIC_CUSTOM_HEADERS` for raw
  endpoints that key off the header directly.
- L3 fallback: if the client hides `[1m]` picker variants behind a tier check, neutralize
  that tier gate so `[1m]` variants are always offered. Sentinel anchored on the 1M-disable
  flag / picker-variant construction.
- **Footgun guarded:** sending `context-1m` unconditionally errors on plans without the long-
  context entitlement ("extra usage is required for long context requests"). This is exactly
  why `context1m` is opt-in and default-off, and why the header path is only added when the
  user explicitly enables it. Honest caveat surfaced in docs: *the client stops refusing; the
  endpoint decides whether 1M actually serves.*

### 4.3 `concurrency` — L3, config-bounded
- Targets the hardcoded caps: parallel-agent slot cap (`min(16, cpuCount-2)` shape),
  the ~1000-agent lifetime backstop, and the 4096-item fan-out cap.
- Replacer reads a bound from an env the wrapper sets (`LLMGOD_MAX_CONCURRENCY`), defaulting
  to a **raised-but-finite** value (proposed 64) rather than infinity — avoids OOM/footgun.
  `config.limits.concurrency` may be `true` (use default bound), a number (explicit bound),
  or absent (no patch).
- Each sub-cap is its own L3 patch with its own sentinel + `optional:true`, so a shape change
  in one doesn't block the others.

### 4.4 `modelAllowlist` — L3
- Strips client-side model-id gating so any model id routes to a compatible endpoint, incl.
  the auto-mode model conditions already seen in the binary
  (`$==="claude-opus-4-6"||…` style). Sentinel anchored on those model-id literals.
- Honest caveat: removing the gate only stops the *client* from rejecting an id; the endpoint
  must actually serve it.

### 4.5 Config → behavior summary

```jsonc
"limits": {
  "context1m": false,        // bool
  "thinkingBudget": 0,       // int tokens; 0 = unset
  "concurrency": false,      // bool | int (bound); true → default bound 64
  "modelAllowlist": false    // bool
}
```

## 5. Module B — Cost & Cache X-ray

### 5.1 Data path
```
globalThis.fetch wrapper (L2, in cli.cjs)
  └─ intercept responses to /v1/messages (incl. streaming SSE message_start/message_delta)
  └─ extract usage: input_tokens, output_tokens,
                    cache_creation_input_tokens, cache_read_input_tokens, model
  └─ accumulate → ~/.llmgod/metering/session-<id>.json   (last-writer-wins, atomic write)

statusLine script (registered in ~/.claude/settings.json)
  └─ reads its stdin (official: model, total_cost_usd, context/duration)
  └─ reads newest ~/.llmgod/metering/session-*.json (cache metrics we add)
  └─ prints one line

llmgod xray  (argv dispatch in cli.cjs, exits before require)
  └─ reads newest (or --all) metering file → full breakdown panel
```

The probe lives in the **wrapper as a `globalThis.fetch` wrapper**, installed before
`require('./cli.original.cjs')` — **not** a regex patch into minified cli.js. This is a
deliberate upgrade over a cli.js-internal probe: it is version-agnostic and survives Claude
upgrades untouched. (Claude Code's SDK uses Bun's global `fetch`; the wrapper runs first, so
the override is in effect. Verification step in §8 confirms the SDK does not capture a private
fetch reference before our override; fallback: also override at the SDK module boundary.)

### 5.2 Metering file schema
`~/.llmgod/metering/session-<id>.json`:
```jsonc
{
  "sessionId": "<uuid>",          // LLMGOD_SESSION, generated by wrapper at startup
  "startedAt": 0, "updatedAt": 0,
  "model": "claude-opus-4-8",
  "turns": 0,
  "tokens": { "input": 0, "output": 0, "cacheCreate": 0, "cacheRead": 0 },
  "cacheHitRate": 0.0,            // cacheRead / (cacheRead + input + cacheCreate)
  "cost": { "usd": 0.0, "priced": true }
}
```
Writes are atomic (temp file + rename). On parse failure the file is reset, never crashes.

### 5.3 statusLine headline (one line)
`ctx 38% · $1.27 · cache 91% · ↑12k/min`
- context % from official statusLine stdin (or our token total vs window).
- `$cost` from official `total_cost_usd` when present, else computed (§5.4).
- `cache %` and burn rate from our metering file (official stdin lacks cache breakdown —
  this is the whole reason the probe exists).
- Degrades gracefully: any unavailable field is dropped from the line, not shown as 0/NaN.

### 5.4 Pricing
- Built-in price table keyed by Anthropic model id (input / output / cacheWrite-5m /
  cacheWrite-1h / cacheRead per Mtok), including the 1M premium tier (>200k).
- `provider.json.pricing` overrides per model — required for third-party endpoints whose
  prices differ.
- Unknown model **and** no override → show tokens only, hide `$` (`cost.priced=false`).
  Never invent a price.

### 5.5 Session correlation (v1 limitation, stated)
Probe keys by `LLMGOD_SESSION` (uuid the wrapper exports at startup). The statusLine and
panel run as separate processes and cannot read that env, so they pick the **newest metering
file by mtime** = the active session. Correct for a single active session; concurrent sessions
may share a headline. Documented as a known v1 tradeoff; true session-id correlation is future
hardening.

### 5.6 `llmgod xray` deep panel
Sibling subcommand, intercepted at the top of `cli.cjs` (`process.argv[2]==='xray'`), renders
and exits before any env setup or require. Shows: per-model split, cache-write vs cache-read,
**1h-cache savings** (read tokens × cacheRead price delta), this-turn vs cumulative, and the
billing-header status (confirms the existing third-party cache fix is engaged). `--all` lists
every recent session.

### 5.7 statusLine registration
On first run, if `xray.statusLine !== false` **and** `~/.claude/settings.json` has no existing
`statusLine`, the wrapper registers our script (idempotent). If the user already has a
statusLine, **do not clobber** — print a one-time hint with the manual snippet instead.

### 5.8 Config
```jsonc
"xray": {
  "enabled": true,
  "statusLine": true        // false → don't auto-register; panel still works
},
"pricing": {
  "claude-opus-4-8": { "input": 15, "output": 75, "cacheWrite1h": 30, "cacheRead": 1.5 }
}
```

## 6. Full `provider.json` additions (backward-compatible)
All new keys are optional and merge over `defaultConfig`; absent → current behavior unchanged.
```jsonc
{
  // ...existing: apiKey, baseURL, model, smallModel, timeoutMs...
  "limits":  { "context1m": false, "thinkingBudget": 0, "concurrency": false, "modelAllowlist": false },
  "xray":    { "enabled": true, "statusLine": true },
  "pricing": { /* modelId: { input, output, cacheWrite1h, cacheRead } per Mtok */ }
}
```

## 7. Error handling & failure modes
| Failure | Behavior |
|---------|----------|
| L3 patch sentinel absent (version drift) | patch skipped (`optional:true`); that ceiling silently inactive; startup OK |
| Probe fetch-wrap throws | caught; no metering written; Claude runs normally |
| Metering file corrupt/unwritable | reset or skip; X-ray shows nothing; no crash |
| Unknown model price | tokens shown, `$` hidden |
| User already has a statusLine | not overwritten; one-time hint printed |
| `context1m` on unsupported endpoint | endpoint returns long-context error — documented; toggle is opt-in/default-off |

## 8. Testing & verification
- **Patch-shape tests:** run `patch.mjs` against a real `cli.original.cjs`; assert each new L3
  patch's sentinel resolves and replacement is idempotent (re-running is a no-op). Reuse the
  existing patcher's verification path.
- **Probe unit test:** feed a captured `/v1/messages` SSE stream through the fetch wrapper;
  assert metering totals match the response `usage` fields.
- **fetch-override verification:** confirm Claude Code's SDK uses `globalThis.fetch` at call
  time (not a pre-captured reference) so the wrapper override is honored; if not, add the
  SDK-boundary fallback. **Gate before declaring the probe done.**
- **End-to-end (manual):** with `limits.thinkingBudget` set, confirm larger thinking budgets;
  with `context1m` on against a 1M-capable endpoint, confirm >200k context accepted; confirm
  statusLine line renders and `llmgod xray` panel matches `/cost`-level numbers.
- **Regression:** with all OVERDRIVE config absent, behavior is byte-for-byte the current build.

## 9. Risks & open questions
- **R1 — fetch capture:** if the SDK captured `fetch` before our wrapper, the probe misses
  requests. Mitigation in §8; fallback SDK-boundary override. *Must verify first.*
- **R2 — 1M tier gate shape:** the L3 fallback for `context1m` depends on the picker/tier
  construction, which may differ across versions. Sentinel + `optional` contains the blast
  radius; L1 (model-env `[1m]`) is the primary path and needs no patch.
- **R3 — concurrency OOM:** unbounded raise is a footgun; default bound 64, user-overridable.
- **R4 — statusLine ownership:** never clobber a user's statusLine; hint-only fallback.

**Resolved decisions**
- **Pricing defaults:** ship the built-in Anthropic price table (§5.4); third-party endpoints
  override via `provider.json.pricing`; unknown + no override → tokens only, `$` hidden.

## 10. Out of scope / future
- Persistent JSONL metrics + graphs.
- True session-id metering correlation (vs newest-by-mtime).
- A real in-CLI `/xray` slash command (vs the `llmgod xray` sibling).
