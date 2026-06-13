# Workflow Studio — Make Claude Code's dynamic Workflow actually usable

> Design spec · 2026-06-13 · branch `feature/workflow-studio`
> Status: **approved for planning** (brainstorming complete)

## 1. Motivation

`llmgod` (Let's LLM) is a runtime patcher for Claude Code. v1.2.0 already flips the
dynamic-Workflow feature **on** (`enableWorkflows:true` + `ultracode:true` seeded into
`~/.claude/settings.json`, never-clobber) and raises one concurrency cap. But that only
makes Workflows *available* — it does nothing to make them *good*. Claude Code's Workflow
tool, as shipped, is:

- **Ephemeral** — every run lives under the current session's transcript dir
  (`…/<session>/subagents/workflows/<runId>/journal.jsonl`, cli.original.cjs `PK$()` @ :3658).
  `resumeFromRunId` is documented same-session-only precisely because the runId resolves
  relative to the *current* session base (`rI()`). Close the session → the run is orphaned.
- **Capped** — concurrency slot cap, a ~1000-agent lifetime backstop (tool desc @ :3765),
  and **nesting limited to one level** — `workflow()` inside a child rejects with
  `"workflow() cannot be called from within a child workflow — nesting is limited to one level"`
  (@ :3607).
- **Opaque** — only the live `/workflows` tree exists; no per-run / per-agent token & cost
  breakdown survives the run, even though llmgod already meters every `/v1/messages` via X-ray.
- **Non-reusable** — Claude Code resolves named workflows from `~/.claude/workflows/<name>.js`
  (@ :8686) but ships **zero** of them and offers no manager. Every workflow is a one-off
  script pasted into the tool.

**This spec turns llmgod into a Workflow enhancer ("Workflow Studio")**: a persistent,
reusable, observable, power-unlocked layer on top of the official Workflow tool — built
entirely on llmgod's existing L1/L2/L3 injection surfaces, anchored to real cli.original.cjs
line evidence, and **honest about what is not patchable**.

### Value anchor & differentiation
- Value: workflows become saveable assets, survive sessions, are resumable across sessions,
  show their cost, and run with raised ceilings.
- Differentiation vs. naive "raise all the limits": every claim is grounded in a real cli
  anchor; the one cap that has **no numeric guard** (fan-out 4096) is excluded with evidence
  rather than guessed at — the same anti-drift discipline that is llmgod's moat.

## 2. Goals / Non-goals

**Goals**
- A first-class `llmgod workflow` subcommand (sibling of `llmgod xray`) for library +
  history + resume management.
- A curated, runnable starter library installed into `~/.claude/workflows/`.
- Cross-session run history, status, and resume.
- Per-workflow / per-agent cost & token observability, reusing the X-ray meter.
- Opt-in raised ceilings: workflow nesting depth, parallel-agent concurrency, lifetime
  agent backstop, plus a fan-out subagent-model lever.
- Cross-run content-addressed result cache (advanced; degradable).
- Every binary-touching change is `sentinel` + `optional` (skip-on-drift), fixture-driven,
  and mirrored sh ↔ ps1 with a parity guard.

**Non-goals (YAGNI)**
- No new in-CLI slash command (`/workflow`) — the manager ships as the `llmgod workflow`
  sibling subcommand, exactly like `llmgod xray`, to avoid patching command registration.
- No GUI / web dashboard for runs in v1 (terminal panel only).
- No attempt to raise the **4096 fan-out item cap** — there is no numeric guard to patch
  (see §6.5); it stays documented-only.
- No re-architecture of Claude Code's Workflow engine; we wrap and gate, we don't rewrite.
- No cross-machine run sync.

## 3. Architecture — extension surfaces

llmgod reuses its three existing injection layers; no new mechanism is invented.

| Layer | Surface (verified) | What Studio adds |
|-------|--------------------|------------------|
| **L2 argv dispatch** | `cli.cjs:1096` `if (process.argv[2]==='xray'){…process.exit(0)}` | sibling `if (process.argv[2]==='workflow')` → manager, before env setup & `require()` |
| **L2 module embed** | `scripts/embed-overdrive.mjs` `MODULES[]` → heredoc blocks in install.sh between `# >>> OVERDRIVE MODULES >>>` anchors; drift-guarded by `test/install-sync.test.mjs` | new `workflow-*.mjs` modules added to `MODULES[]` |
| **L1 env** | `cli.cjs:1218-1223` applies `limitEnv(config.limits, env)` plan | new `config.workflow.*` → env via an extended/parallel plan function |
| **L2 probe** | `cli.cjs:1225-1231` `installProbe(config, dir, sid)` (X-ray) | meter buckets keyed by workflow run |
| **L3 patch** | `src/overdrive/patches.mjs` `{name,sentinel,optional,pattern,replacer}`, mirrored into install.sh patch.mjs | nesting-depth guard; concurrency re-fixture; lifetime backstop |

**New on-disk surfaces**
- `~/.claude/workflows/<name>.js` — Claude Code's native named-workflow registry
  (resolver @ :8686). Studio writes curated library files here and lists/creates them.
- `~/.llmgod/workflows/` — Studio's own state: `index.json` (run catalog), and
  `cache/` (pillar 5 result cache). Never collides with CC's per-session run dirs.

**Claude Code internals grounding (cli.original.cjs, version stamped in `~/.llmgod/.source-version`)**

| Concern | Anchor | Note |
|---------|--------|------|
| Gating | `enableWorkflows`/`disableWorkflows` settings + `CLAUDE_CODE_DISABLE_WORKFLOWS` (`:184`,`:266`,`:7485`) | already seeded on by llmgod; no new work |
| Named registry | `~/.claude/workflows/${name}.js` (`:8686`); `.claude/workflows/` (`:2613`,`:4057`) | pillar 1 |
| Run dir + journal | `PK$(H)=join(rI()??BO(W6()), N$(),"subagents","workflows",H)`; `journal.jsonl`; `k24(runId,{script,scriptPath,args,result,…})` (`:3658`) | pillars 2,4,5 |
| Run record | `ms6({taskId,script,scriptPath,args,summary,workflowName,transcriptDir,workflowRunId})` (`:3364`) | pillars 2,4 |
| Nesting guard | reject `"…nesting is limited to one level"` (`:3607`) | pillar 3 (L3, patchable) |
| Subagent model | `CLAUDE_CODE_SUBAGENT_MODEL` (supports `"inherit"`) (`:2429`,`:131`,`:2773`) | pillar 3 (L1) |
| Concurrency cap | `Math.min(16,Math.max(2,H-2))` shape from `src/overdrive/fixtures/concurrency-slot.txt` **NOT present in current binary** | existing patch drifted; re-fixture (§6.3) |
| Lifetime 1000 | tool desc `:3765`; numeric enforcement not yet located | pillar 3 (fixture during impl) |
| Fan-out 4096 | all `4096` literals are `Buffer.alloc`/read-size/unrelated consts | **no guard → excluded** (§6.5) |

## 4. Pillar 1 — Workflow library + manager (L2, no patch)

A new module `overdrive/workflow-cli.mjs`, dispatched from the wrapper when
`process.argv[2]==='workflow'`. Subcommands:

| Command | Behavior |
|---------|----------|
| `llmgod workflow ls` | list `~/.claude/workflows/*.js` (name, description from `meta`, source: builtin/user) + project `./.claude/workflows/*.js` |
| `llmgod workflow run <name> [--args <json>]` | resolve `<name>.js`, hand off to Claude Code's own named-workflow path (the manager does **not** re-implement the engine). *Deferred past M1 — needs a headless-launch path; in M1 you run a workflow via the in-session `Workflow({name})` tool* |
| `llmgod workflow new <name>` | scaffold `~/.claude/workflows/<name>.js` from a template (valid `meta` literal + sample phase/agent) |
| `llmgod workflow save <runId> <name>` | copy the script of a past run (from its journal `script`/`scriptPath`) into the library as `<name>.js`. *Deferred past M1 — needs Pillar 2 run discovery* |
| `llmgod workflow rm <name>` | remove a library file (only llmgod-managed / confirmed) |

> **M1 scope (refined during planning):** M1 ships `ls` / `new` / `rm` / `help` only; `run` and
> `save` are deferred to later milestones (see §12 and the M1 plan). M1's curated library ships
> **`review.js` only** — `research.js` / `understand.js` are trivial later additions (one
> `STARTER_LIBRARY` entry each, no code change).

**Curated starter library** (seeded once, never-clobber, only when the file is absent):
- `review.js` — changed-files review → adversarial verify (the canonical pipeline pattern) — **ships in M1**
- `research.js` — multi-source web sweep → dedupe → synthesize — *later*
- `understand.js` — parallel readers over subsystems → structured map — *later*
Each ships as a self-contained, parameterized (`args`) script with a pure-literal `meta`.

Seeding is gated by `config.workflow.library !== false` and follows the same never-clobber
rule as the settings seed (write only when the target file does not exist).

## 5. Pillar 2 — Cross-session persistence, history, resume (L2 + ≤1 L3)

**Run discovery (read-only, L2).** Studio scans `~/.claude/projects/*/*/subagents/workflows/wf_*/`
across **all** projects/sessions (the path shape is fixed by `PK$()` @ :3658), reads each
run's `journal.jsonl` + run record, and maintains a denormalized catalog at
`~/.llmgod/workflows/index.json` (append/update on `llmgod workflow` invocation; the journals
remain the source of truth).

| Command | Behavior |
|---------|----------|
| `llmgod workflow list [--all]` | table of recent runs across sessions: runId, workflowName, status, when, duration, agents, $cost (joined from X-ray, §7) |
| `llmgod workflow status <runId>` | one run's detail: per-phase/per-agent breakdown from the journal + metering |
| `llmgod workflow resume <runId>` | re-enter a past run regardless of originating session |

**Resume across sessions.** The blocker is that `resumeFromRunId` resolves the run dir under
the *current* session base (`rI()`), so a run from another session is invisible. Two viable
mechanisms, decided during implementation against the real binary:
- **(A) Relocate/symlink (L2, preferred, zero patch):** before invoking the native
  `Workflow({scriptPath, resumeFromRunId})`, Studio links/copies the target run dir into the
  current session's `…/subagents/workflows/<runId>/` so the native resolver finds it.
- **(B) Resolver patch (L3 fallback):** a `sentinel`+`optional` patch widening `PK$()`/the
  runId lookup to also search `~/.llmgod/workflows/runs/` if the run is absent under the
  current session.

Preference order is A then B; B only if A proves unreliable. Both degrade safely: if resume
can't bind the run, the command prints the native copy-paste invocation (already emitted by
CC @ :3364) and exits non-zero — never corrupts a session.

## 6. Pillar 3 — Raised ceilings / raw power (L1 + L3)

All ceilings are **opt-in** via `config.workflow.*`; absent ⇒ current behavior unchanged.

### 6.1 Fan-out subagent model — L1, zero risk ✅
`config.workflow.fanoutModel` → `process.env.CLAUDE_CODE_SUBAGENT_MODEL` (real env @ :2429,
accepts a model id or `"inherit"`). Lets fan-out workers run a cheaper/faster model than the
orchestrator. Pure env injection through the limits plan; no patch.

### 6.2 Workflow nesting depth — L3, env-gated
Anchor: the reject at :3607 (`"…nesting is limited to one level"`). Add a `sentinel`+`optional`
patch that makes the one-level guard conditional on `LLMGOD_MAX_WORKFLOW_DEPTH` (set from
`config.workflow.maxDepth`, default `1`). When the env is unset or `1`, the original guard
stands (inert patch). The depth counter itself, if numeric, is bounded by `maxDepth`; if the
guard is a pure boolean (no counter), the patch flips it to allow nesting only when the env
is set, and depth is then advisory. Fixture captured from the real binary before the regex is
finalized; if the construct is absent on a version, the patch skips (feature inactive, install OK).

### 6.3 Parallel-agent concurrency — L3 re-fixture + L1
The shipped patch targets `Math.min(16,Math.max(2,H-2))`, which is **absent** in the current
binary (confirmed: no `Math.min(16` match). This is a live drift defect: the concurrency
unlock is currently inert. Implementation re-locates the current slot-cap construct from a
fresh fixture and rewrites the patch, keeping the existing `LLMGOD_MAX_CONCURRENCY` env lever
(`limits-env.mjs:21-25`). Also covered by the parity test (§7).

### 6.4 Lifetime agent backstop (~1000) — L3, fixture-driven
The 1000-agent lifetime cap is described at :3765 but its numeric enforcement is not yet
located. Implementation greps the real binary for the agent-counter comparison, adds a
`sentinel`+`optional` patch raising it to a **raised-but-finite** bound (env
`LLMGOD_MAX_CONCURRENCY` or a dedicated `LLMGOD_AGENT_LIFETIME`), never to infinity (runaway
guard). If no numeric enforcement is found, document prose-only and skip — do not guess.

### 6.5 Fan-out 4096 item cap — EXCLUDED (evidence-based)
Every `4096` literal in the binary is a `Buffer.alloc` / `readSync` length / unrelated
constant; the fan-out cap is prose inside the tool description, with **no numeric guard to
patch**. This is documented as a known non-feature. We do not invent a patch.

### 6.6 Config → env summary
```jsonc
"workflow": {
  "fanoutModel": "",        // → CLAUDE_CODE_SUBAGENT_MODEL ("" = unset)
  "maxDepth": 1,            // → LLMGOD_MAX_WORKFLOW_DEPTH (>1 opt-in, L3)
  "maxConcurrency": false,  // bool|int → LLMGOD_MAX_CONCURRENCY (reuse limits-env)
  "agentLifetime": false    // bool|int → LLMGOD_AGENT_LIFETIME (L3, if guard found)
}
```

## 7. Pillar 4 — Per-workflow X-ray (L2)

Reuse the existing OVERDRIVE meter (`overdrive/metering.mjs`, `probe.mjs`). The probe already
intercepts `/v1/messages`; extend it to **bucket usage by workflow run** when the request
correlates to one. Correlation source, in preference order: (a) request metadata carried by
subagent calls; (b) time-window join against the active run dir mtime. The bucketed metrics
land in `~/.llmgod/workflows/index.json` alongside the run catalog (§5), so:
- `llmgod workflow status <runId>` shows per-agent / per-phase token & `$cost`.
- `llmgod workflow list` shows a `$cost` column.

Degrades safely (X-ray discipline): if correlation fails, the run still lists with tokens
omitted, never a wrong number; metering failure never perturbs the Claude process.

## 8. Pillar 5 — Cross-run result cache (L2/L3, advanced, degradable)

Content-address each `agent()` call by `hash(prompt + canonical(opts))` and persist its result
under `~/.llmgod/workflows/cache/<hash>.json`. On a later run, an identical call is served from
cache instead of spawning an agent. The journal (@ :3658) already proves agent results are
serializable and is the in-run precedent.

Mechanism (decided during impl against the binary):
- **Preferred:** an `optional` L3 hook at the agent-execution point that consults the llmgod
  cache before dispatch and writes through on completion, gated by `config.workflow.cache`.
- **Fallback / downgrade:** if no clean single hook point exists, downgrade to a
  *same-session journal-reuse enhancement* (improve cache-hit on the existing
  `resumeFromRunId` prefix mechanism) and document the cross-run cache as deferred.

`cache` defaults **off**. Staleness is the user's call: `llmgod workflow cache --clear`.

## 9. Full `provider.json` additions (backward-compatible)
All keys optional; absent ⇒ current behavior byte-for-byte.
```jsonc
{
  // …existing: apiKey, baseURL, model, smallModel, timeoutMs, limits, xray, pricing…
  "workflow": {
    "library": true,          // seed curated ~/.claude/workflows/*.js (never-clobber)
    "index": true,            // maintain ~/.llmgod/workflows/index.json run catalog
    "fanoutModel": "",        // CLAUDE_CODE_SUBAGENT_MODEL
    "maxDepth": 1,            // LLMGOD_MAX_WORKFLOW_DEPTH
    "maxConcurrency": false,  // LLMGOD_MAX_CONCURRENCY
    "agentLifetime": false,   // LLMGOD_AGENT_LIFETIME
    "cache": false            // cross-run result cache
  }
}
```

## 10. Error handling & failure modes
| Failure | Behavior |
|---------|----------|
| `argv[2]==='workflow'` module throws | caught; print error + usage; `process.exit(1)`; never falls through to launch the CLI in a half-set state |
| Library seed: file exists | never clobbered (seed only when absent) |
| Run scan hits an unreadable/corrupt journal | skip that run; catalog the rest; no crash |
| Resume can't bind a cross-session run | print native `Workflow({scriptPath,resumeFromRunId})` invocation; exit non-zero |
| L3 patch sentinel absent (drift) | patch skipped (`optional`); that ceiling inert; install OK |
| Concurrency/nesting/lifetime guard not found | feature inactive + logged; documented, not fatal |
| Probe correlation fails | run lists with tokens omitted; metering never perturbs CLI |
| Result cache read/write error | bypass cache (spawn normally); never breaks a run |
| All `config.workflow` absent | zero behavior change |

## 11. Testing & verification
- **Patch-shape tests:** each new L3 patch runs against the real `~/.llmgod/cli.original.cjs`;
  assert sentinel resolves, exactly-N match, idempotent re-run. Capture fixtures into
  `src/overdrive/fixtures/` (nesting-guard, concurrency-slot-current, lifetime-backstop).
- **Manager unit tests:** `llmgod workflow ls/new/save/list/status` against a temp HOME with
  synthetic `~/.claude/workflows/` files and synthetic run dirs + `journal.jsonl`.
- **Probe bucket test:** feed a captured multi-agent SSE stream; assert per-run token totals.
- **sh ↔ ps1 parity test (M4):** new `test/installer-parity.test.mjs` asserts both installers
  embed the same workflow modules + functional L3 patch `name:` set (also catches the
  pre-existing missing-patches-on-ps1 defect). Lands with M4; until then ps1 intentionally
  lacks the workflow modules (sh-first, §12).
- **Drift guard:** extend `test/install-sync.test.mjs` to cover the new embedded modules.
- **Regression:** with all `config.workflow` absent and no library/runs, behavior is
  byte-for-byte the current build.
- **Verification gate:** `bun test` green + a real `llmgod workflow ls`/`list` against this
  machine's actual run dirs before any milestone is declared done.

## 12. Milestones (each implemented via a parallel workflow)
M1–M3 target **macOS/Linux only** (install.sh); Windows is a dedicated follow-on (decision
R5 = sh-first, §13).
- **M1 — usable now, zero patch:** Pillar 1 (library + manager: `ls`/`new`/`rm`/`help`, curated
  `review` seed). Pure L2; ships the visible win first. *(Planning refinement: Pillar 4
  per-workflow X-ray depends on Pillar 2's run discovery and moved to M2; `run`/`save` deferred
  likewise — see §4 note.)*
- **M2 — persistence + L1 power:** Pillar 2 (cross-session history/resume) + Pillar 3 L1
  (fanoutModel) + Pillar 3 nesting patch (6.2).
- **M3 — deep power + cache:** Pillar 3 concurrency re-fixture (6.3) + lifetime (6.4) +
  Pillar 5 (result cache, with downgrade path).
- **M4 — Windows parity:** port the OVERDRIVE base (X-ray probe + modules + the 2 existing
  L3 patches, currently absent on ps1) **and** the Studio modules/patches into install.ps1;
  add the sh ↔ ps1 parity test (§11).
- Each milestone: src module(s) + tests + `embed-overdrive` regen + install.sh +
  sentinel/optional on every patch. ps1 changes are concentrated in M4.

## 13. Risks & open questions
- **R1 — concurrency drift (confirmed):** the shipped slot-cap patch no longer matches; M3
  must re-fixture. Mitigated by the parity/patch-shape tests becoming a permanent guard.
- **R2 — cross-session resume:** approach A (relocate/symlink) vs B (resolver patch); A
  preferred, B fixture-gated. Degrades to copy-paste invocation.
- **R3 — result cache hook point (highest risk):** may have no clean single agent-exec hook;
  explicit downgrade path to same-session journal reuse (§8). Never guess a hook.
- **R4 — lifetime enforcement may be unlocatable:** prose-only fallback, skip the patch.
- **R5 — Windows parity (RESOLVED: sh-first):** install.ps1 currently ships no OVERDRIVE
  wiring at all. Decision: M1–M3 are macOS/Linux only; Windows parity (port the OVERDRIVE
  base + the Studio layer into install.ps1) is a dedicated follow-on milestone **M4** (§12).
  Keeps the main line fast; the maintainer's environment is Linux.

## 14. Out of scope / future
- `/workflow` in-CLI slash command (vs the `llmgod workflow` sibling).
- Web/GUI run dashboard.
- Cross-machine run sync / shared team library.
- Raising the 4096 fan-out cap (no guard exists).
