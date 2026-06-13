# Workflow Studio M1 — Library + Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a curated, listable, extensible Workflow library + an `llmgod workflow` manager — purely via llmgod's L2 wrapper, zero binary patching.

**Architecture:** Two new pure ES modules under `src/overdrive/` (`workflow-cli.mjs`, `workflow-library.mjs`), embedded into `install.sh` by the existing `embed-overdrive.mjs` pipeline. The wrapper (`cli.cjs`) gains an `argv[2]==='workflow'` dispatch (sibling of the existing `xray` dispatch at `install.sh:1096`) and a runtime, never-clobber seeding step that writes the starter library into `~/.claude/workflows/` (Claude Code's native named-workflow registry, resolver at `cli.original.cjs:8686`). Running a workflow uses Claude Code's own `Workflow({name})` path — the manager only curates/lists/scaffolds.

**Tech Stack:** Bun (runtime + `bun:test`), ES modules (`.mjs`), POSIX shell (`install.sh`), dependency-injected `fs` for unit-test purity.

**Scope note (refined from spec §12):** M1 = **Pillar 1 only**. Per-workflow X-ray (Pillar 4) depends on Pillar 2's cross-session run discovery, so it moves to M2. Manager subcommands in M1: `ls`, `new`, `rm`, `help`. `run`/`save`/`list`/`status`/`resume` are later milestones (they need run discovery or a headless-launch path).

**Conventions (verified in repo):**
- Tests: `import { test, expect } from "bun:test";` — run with `bun test`.
- Modules: pure exported functions + an `if (import.meta.main) { … }` CLI tail.
- Inject `fs`/`out` deps into logic functions so tests need no real filesystem.
- Drift guard `test/install-sync.test.mjs` iterates a module list and asserts the embedded body equals the source; new modules MUST be added there and to `scripts/embed-overdrive.mjs` `MODULES[]`.

---

### Task 1: `parseWorkflowMeta` — extract name/description from a workflow file

**Files:**
- Create: `src/overdrive/workflow-cli.mjs`
- Test: `src/overdrive/workflow-cli.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
// src/overdrive/workflow-cli.test.mjs
import { test, expect } from "bun:test";
import { parseWorkflowMeta } from "./workflow-cli.mjs";

test("parseWorkflowMeta pulls name and description from a meta literal", () => {
  const src = `export const meta = {\n  name: 'review',\n  description: 'Review the diff',\n  phases: [],\n}`;
  expect(parseWorkflowMeta(src)).toEqual({ name: "review", description: "Review the diff" });
});

test("parseWorkflowMeta returns name with empty description when description absent", () => {
  expect(parseWorkflowMeta(`export const meta = { name: "x" }`)).toEqual({ name: "x", description: "" });
});

test("parseWorkflowMeta returns null when no name", () => {
  expect(parseWorkflowMeta("const x = 1")).toBeNull();
  expect(parseWorkflowMeta(123)).toBeNull();
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: FAIL — `parseWorkflowMeta` is not exported / module not found.

- [ ] **Step 3: Write minimal implementation**

```js
// src/overdrive/workflow-cli.mjs
import { join } from "path";

// Extract { name, description } from a workflow file's `export const meta = {...}`.
// Defensive regex (does not execute the file); returns null when there is no name.
export function parseWorkflowMeta(source) {
  if (typeof source !== "string") return null;
  const name = source.match(/name\s*:\s*['"]([^'"]+)['"]/);
  if (!name) return null;
  const desc = source.match(/description\s*:\s*['"]([^'"]+)['"]/);
  return { name: name[1], description: desc ? desc[1] : "" };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/workflow-cli.mjs src/overdrive/workflow-cli.test.mjs
git commit -m "feat(workflow): parseWorkflowMeta for library listing"
```

---

### Task 2: `listWorkflows` — enumerate user + project workflows

**Files:**
- Modify: `src/overdrive/workflow-cli.mjs`
- Test: `src/overdrive/workflow-cli.test.mjs`

- [ ] **Step 1: Write the failing test** (append)

```js
import { listWorkflows } from "./workflow-cli.mjs";

function fakeFs(files) {
  // files: { "<dir>": { "<file>": "<contents>" } }
  const dirOf = (p) => p.slice(0, p.lastIndexOf("/"));
  const baseOf = (p) => p.slice(p.lastIndexOf("/") + 1);
  return {
    existsSync: (p) => p in files || (dirOf(p) in files && baseOf(p) in files[dirOf(p)]),
    readdirSync: (p) => Object.keys(files[p] || {}),
    readFileSync: (p) => files[dirOf(p)][baseOf(p)],
  };
}

test("listWorkflows lists .js files from user and project dirs with parsed meta", () => {
  const fs = fakeFs({
    "/u/wf": { "review.js": `export const meta = { name: 'review', description: 'Review diff' }`, "notes.txt": "x" },
    "/p/wf": { "deploy.js": `export const meta = { name: 'deploy' }` },
  });
  const rows = listWorkflows([{ scope: "user", path: "/u/wf" }, { scope: "project", path: "/p/wf" }], fs);
  expect(rows).toEqual([
    { name: "review", description: "Review diff", scope: "user", path: "/u/wf/review.js" },
    { name: "deploy", description: "", scope: "project", path: "/p/wf/deploy.js" },
  ]);
});

test("listWorkflows skips missing dirs and non-.js files", () => {
  const fs = fakeFs({ "/u/wf": { "a.js": `export const meta = { name: 'a' }`, "b.md": "x" } });
  const rows = listWorkflows([{ scope: "user", path: "/u/wf" }, { scope: "project", path: "/nope" }], fs);
  expect(rows.map((r) => r.name)).toEqual(["a"]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: FAIL — `listWorkflows` not exported.

- [ ] **Step 3: Write minimal implementation** (append to `workflow-cli.mjs`)

```js
// dirs: [{ scope, path }]; fs: { existsSync, readdirSync, readFileSync }.
// Returns [{ name, description, scope, path }] for every *.js workflow found.
export function listWorkflows(dirs, fs) {
  const out = [];
  for (const { scope, path } of dirs) {
    if (!fs.existsSync(path)) continue;
    for (const f of fs.readdirSync(path)) {
      if (!f.endsWith(".js")) continue;
      const full = join(path, f);
      let meta = null;
      try { meta = parseWorkflowMeta(fs.readFileSync(full, "utf8")); } catch {}
      out.push({ name: meta?.name ?? f.replace(/\.js$/, ""), description: meta?.description ?? "", scope, path: full });
    }
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/workflow-cli.mjs src/overdrive/workflow-cli.test.mjs
git commit -m "feat(workflow): listWorkflows across user + project registries"
```

---

### Task 3: `scaffoldWorkflow` + `validName` — new-workflow template

**Files:**
- Modify: `src/overdrive/workflow-cli.mjs`
- Test: `src/overdrive/workflow-cli.test.mjs`

- [ ] **Step 1: Write the failing test** (append)

```js
import { scaffoldWorkflow, validName } from "./workflow-cli.mjs";

test("validName accepts kebab/alnum, rejects path-y or empty", () => {
  expect(validName("review")).toBe(true);
  expect(validName("my-flow_2")).toBe(true);
  expect(validName("")).toBe(false);
  expect(validName("../evil")).toBe(false);
  expect(validName("a/b")).toBe(false);
});

test("scaffoldWorkflow emits a runnable skeleton with a pure-literal meta", () => {
  const s = scaffoldWorkflow("demo");
  expect(s).toContain("export const meta = {");
  expect(s).toContain("name: 'demo'");
  expect(s).toContain("await agent(");
  expect(s).toContain("phase(");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: FAIL — `scaffoldWorkflow`/`validName` not exported.

- [ ] **Step 3: Write minimal implementation** (append to `workflow-cli.mjs`)

```js
export function validName(name) {
  return typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name);
}

// A runnable starter the user fills in. The TODOs are intentional scaffold
// content for the end user, not plan placeholders.
export function scaffoldWorkflow(name) {
  return [
    "export const meta = {",
    "  name: '" + name + "',",
    "  description: 'TODO: one-line description of " + name + "',",
    "  phases: [{ title: 'Main' }],",
    "}",
    "",
    "phase('Main')",
    "const result = await agent('TODO: describe the task for this agent')",
    "return { result }",
    "",
  ].join("\n");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/workflow-cli.mjs src/overdrive/workflow-cli.test.mjs
git commit -m "feat(workflow): scaffoldWorkflow + validName"
```

---

### Task 4: `runWorkflowCli` dispatch (ls/new/rm/help) + CLI tail

**Files:**
- Modify: `src/overdrive/workflow-cli.mjs`
- Test: `src/overdrive/workflow-cli.test.mjs`

- [ ] **Step 1: Write the failing test** (append)

```js
import { runWorkflowCli } from "./workflow-cli.mjs";

function harness(files) {
  const store = JSON.parse(JSON.stringify(files)); // { "<dir>": { "<file>": "<contents>" } }
  let outText = "", errText = "";
  const dirOf = (p) => p.slice(0, p.lastIndexOf("/"));
  const baseOf = (p) => p.slice(p.lastIndexOf("/") + 1);
  const fs = {
    existsSync: (p) => p in store || (dirOf(p) in store && baseOf(p) in store[dirOf(p)]),
    readdirSync: (p) => Object.keys(store[p] || {}),
    readFileSync: (p) => store[dirOf(p)][baseOf(p)],
    writeFileSync: (p, c) => { (store[dirOf(p)] ??= {})[baseOf(p)] = c; },
    unlinkSync: (p) => { delete store[dirOf(p)][baseOf(p)]; },
    mkdirSync: (p) => { store[p] ??= {}; },
  };
  const code = (argv) => runWorkflowCli({
    argv, homeDir: "/home/u", cwd: "/proj",
    out: (s) => { outText += s; }, err: (s) => { errText += s; }, fs,
  });
  return { code, store, out: () => outText, err: () => errText };
}

test("ls prints user + project workflows", () => {
  const h = harness({ "/home/u/.claude/workflows": { "review.js": `export const meta = { name: 'review', description: 'R' }` } });
  expect(h.code(["ls"])).toBe(0);
  expect(h.out()).toContain("review");
  expect(h.out()).toContain("user");
});

test("new creates a file, refuses to clobber", () => {
  const h = harness({});
  expect(h.code(["new", "demo"])).toBe(0);
  expect(h.store["/home/u/.claude/workflows"]["demo.js"]).toContain("name: 'demo'");
  expect(h.code(["new", "demo"])).toBe(1); // already exists
  expect(h.err()).toContain("exists");
});

test("new rejects an invalid name", () => {
  const h = harness({});
  expect(h.code(["new", "../evil"])).toBe(1);
  expect(h.err()).toContain("invalid");
});

test("rm deletes an existing user workflow, errors when absent", () => {
  const h = harness({ "/home/u/.claude/workflows": { "x.js": "export const meta = { name: 'x' }" } });
  expect(h.code(["rm", "x"])).toBe(0);
  expect(h.store["/home/u/.claude/workflows"]["x.js"]).toBeUndefined();
  expect(h.code(["rm", "x"])).toBe(1);
});

test("no/unknown subcommand prints usage and returns 0", () => {
  const h = harness({});
  expect(h.code([])).toBe(0);
  expect(h.out()).toContain("llmgod workflow");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: FAIL — `runWorkflowCli` not exported.

- [ ] **Step 3: Write minimal implementation** (append to `workflow-cli.mjs`)

```js
const USAGE = [
  "llmgod workflow — manage the Claude Code workflow library",
  "",
  "  ls                list user + project workflows",
  "  new <name>        scaffold ~/.claude/workflows/<name>.js",
  "  rm  <name>        remove ~/.claude/workflows/<name>.js",
  "",
  "Run a workflow from inside Claude Code with: Workflow({ name: '<name>' })",
  "",
].join("\n");

// deps: { argv (after 'workflow'), homeDir, cwd, out, err, fs }. Returns exit code.
export function runWorkflowCli({ argv, homeDir, cwd, out, err, fs }) {
  const userDir = join(homeDir, ".claude", "workflows");
  const projDir = join(cwd, ".claude", "workflows");
  const [sub, arg] = argv;

  if (sub === "ls") {
    const rows = listWorkflows([{ scope: "user", path: userDir }, { scope: "project", path: projDir }], fs);
    if (!rows.length) { out("(no workflows; create one with: llmgod workflow new <name>)\n"); return 0; }
    for (const r of rows) out(`${r.name}\t[${r.scope}]\t${r.description}\n`);
    return 0;
  }

  if (sub === "new") {
    if (!validName(arg)) { err("invalid name: " + arg + "\n"); return 1; }
    const p = join(userDir, arg + ".js");
    if (fs.existsSync(p)) { err("exists: " + p + "\n"); return 1; }
    if (!fs.existsSync(userDir)) fs.mkdirSync(userDir, { recursive: true });
    fs.writeFileSync(p, scaffoldWorkflow(arg));
    out("created " + p + "\n");
    return 0;
  }

  if (sub === "rm") {
    if (!validName(arg)) { err("invalid name: " + arg + "\n"); return 1; }
    const p = join(userDir, arg + ".js");
    if (!fs.existsSync(p)) { err("not found: " + p + "\n"); return 1; }
    fs.unlinkSync(p);
    out("removed " + p + "\n");
    return 0;
  }

  out(USAGE);
  return 0;
}

if (import.meta.main) {
  const fs = await import("fs");
  const os = await import("os");
  const code = runWorkflowCli({
    argv: process.argv.slice(2),
    homeDir: os.homedir(),
    cwd: process.cwd(),
    out: (s) => process.stdout.write(s),
    err: (s) => process.stderr.write(s),
    fs,
  });
  process.exit(code);
}
```

Note: `process.argv.slice(2)` because the wrapper invokes this module as `bun workflow-cli.mjs <sub> <args…>` (the `workflow` token is consumed by the wrapper, see Task 6).

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/overdrive/workflow-cli.test.mjs`
Expected: PASS (all tasks-1..4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/workflow-cli.mjs src/overdrive/workflow-cli.test.mjs
git commit -m "feat(workflow): runWorkflowCli dispatch (ls/new/rm/help)"
```

---

### Task 5: `workflow-library.mjs` — curated starter + never-clobber seeding

**Files:**
- Create: `src/overdrive/workflow-library.mjs`
- Test: `src/overdrive/workflow-library.test.mjs`

- [ ] **Step 1: Write the failing test**

```js
// src/overdrive/workflow-library.test.mjs
import { test, expect } from "bun:test";
import { STARTER_LIBRARY, seedLibrary } from "./workflow-library.mjs";

test("STARTER_LIBRARY entries are valid pure-literal workflows", () => {
  expect(STARTER_LIBRARY.length).toBeGreaterThan(0);
  for (const { name, source } of STARTER_LIBRARY) {
    expect(name).toMatch(/^[a-z][a-z0-9-]*$/);
    expect(source).toContain("export const meta = {");
    expect(source).toContain("name: '" + name + "'");
    expect(source).not.toContain("OVERDRIVE_"); // no embed-delimiter collision
  }
});

test("seedLibrary writes absent files and never clobbers existing", () => {
  const store = { "/wf": { "review.js": "USER EDITED" } };
  const fs = {
    existsSync: (p) => p === "/wf" || (p.startsWith("/wf/") && p.slice(4) in store["/wf"]),
    mkdirSync: () => {},
    writeFileSync: (p, c) => { store["/wf"][p.slice(4)] = c; },
  };
  const seeded = seedLibrary("/wf", fs);
  expect(store["/wf"]["review.js"]).toBe("USER EDITED");   // not clobbered
  expect(seeded).not.toContain("review");
  // a non-pre-existing starter (if any besides review) gets written:
  for (const { name } of STARTER_LIBRARY) if (name !== "review") expect(seeded).toContain(name);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test src/overdrive/workflow-library.test.mjs`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```js
// src/overdrive/workflow-library.mjs
import { join } from "path";

// Curated starter workflows seeded into ~/.claude/workflows/ (never-clobber).
// IMPORTANT: keep each `source` free of backticks and ${ } so it survives being
// stored in this template literal AND embedded into install.sh's single-quoted
// heredoc unchanged.
const REVIEW = [
  "export const meta = {",
  "  name: 'review',",
  "  description: 'Review the git diff across dimensions, then adversarially verify each finding',",
  "  phases: [{ title: 'Review' }, { title: 'Verify' }],",
  "}",
  "",
  "const DIMENSIONS = [",
  "  { key: 'bugs', prompt: 'Run: git diff. Find correctness bugs in the diff. Return concrete findings.' },",
  "  { key: 'security', prompt: 'Run: git diff. Find security issues in the diff. Return concrete findings.' },",
  "]",
  "",
  "const FINDINGS = { type: 'object', properties: { findings: { type: 'array', items: {",
  "  type: 'object', properties: { title: { type: 'string' }, detail: { type: 'string' } }, required: ['title','detail'] } } }, required: ['findings'] }",
  "const VERDICT = { type: 'object', properties: { isReal: { type: 'boolean' }, reason: { type: 'string' } }, required: ['isReal','reason'] }",
  "",
  "const results = await pipeline(",
  "  DIMENSIONS,",
  "  (d) => agent(d.prompt, { label: 'review:' + d.key, phase: 'Review', schema: FINDINGS }),",
  "  (review, d) => parallel((review.findings || []).map((f) => () =>",
  "    agent('Adversarially verify; default isReal=false if unsure: ' + f.title + ' -- ' + f.detail,",
  "      { label: 'verify:' + d.key, phase: 'Verify', schema: VERDICT }).then((v) => ({ ...f, dimension: d.key, verdict: v })))),",
  ")",
  "const confirmed = results.flat().filter(Boolean).filter((f) => f.verdict && f.verdict.isReal)",
  "return { confirmed, total: confirmed.length }",
  "",
].join("\n");

export const STARTER_LIBRARY = [
  { name: "review", source: REVIEW },
];

// Write each starter into `dir` only when the target file is absent.
// fs: { existsSync, mkdirSync, writeFileSync }. Returns names actually written.
export function seedLibrary(dir, fs) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const seeded = [];
  for (const { name, source } of STARTER_LIBRARY) {
    const p = join(dir, name + ".js");
    if (fs.existsSync(p)) continue;
    fs.writeFileSync(p, source);
    seeded.push(name);
  }
  return seeded;
}
```

Note: the second `seedLibrary` test asserts other starters are written; with only `review` shipped in M1 that loop is vacuous (passes). Additional starters (`research`, `understand`) are added later by appending entries to `STARTER_LIBRARY` — no code change.

- [ ] **Step 4: Run test to verify it passes**

Run: `bun test src/overdrive/workflow-library.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/overdrive/workflow-library.mjs src/overdrive/workflow-library.test.mjs
git commit -m "feat(workflow): curated starter library + never-clobber seedLibrary"
```

---

### Task 6: Wire into the wrapper + embed + drift guard

**Files:**
- Modify: `scripts/embed-overdrive.mjs:11` (MODULES list)
- Modify: `install.sh` (wrapper: argv dispatch + seeding; re-embed regenerates the module region)
- Modify: `test/install-sync.test.mjs:16` (module list) and add wiring assertions

- [ ] **Step 1: Add the new modules to the drift guard test (failing first)**

In `test/install-sync.test.mjs`, change the module loop list (line 16) to include the two new modules, and add a wiring test:

```js
for (const f of ["pricing.mjs", "metering.mjs", "probe.mjs", "statusline.mjs", "panel.mjs", "limits-env.mjs", "workflow-cli.mjs", "workflow-library.mjs"]) {
```

Append:

```js
test("cli.cjs wires the workflow subcommand + library seeding", () => {
  expect(sh).toContain("process.argv[2] === 'workflow'");
  // Assert the wrapper CALL SITE, not the embedded module's own `seedLibrary` definition.
  expect(sh).toContain("seedLibrary(join(homedir(), '.claude', 'workflows')");
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun test test/install-sync.test.mjs`
Expected: FAIL — `install.sh` does not yet embed `workflow-cli.mjs`/`workflow-library.mjs` and lacks the wiring strings.

- [ ] **Step 3: Add modules to the embedder**

In `scripts/embed-overdrive.mjs` line 11:

```js
const MODULES = ["pricing.mjs", "metering.mjs", "probe.mjs", "statusline.mjs", "panel.mjs", "limits-env.mjs", "workflow-cli.mjs", "workflow-library.mjs"];
```

- [ ] **Step 4: Add the argv dispatch to the wrapper**

In `install.sh`, immediately after the `xray` dispatch block (the lines containing `if (process.argv[2] === 'xray') { … process.exit(0); }`, around `install.sh:1096-1099`), insert:

```js
// Studio: `llmgod workflow <sub>` library manager — handle before launch, then exit.
if (process.argv[2] === 'workflow') {
  const r = spawnSync(process.execPath, [join(llmgodDir, 'overdrive', 'workflow-cli.mjs'), ...process.argv.slice(3)], { stdio: 'inherit' });
  process.exit(r.status ?? 0);
}
```

- [ ] **Step 5: Add never-clobber library seeding to the wrapper**

In `install.sh`, inside the async IIFE that applies the limits plan and installs the probe (around `install.sh:1214-1231`), after the probe block and before `require('./cli.original.cjs');`, insert:

```js
  try {
    if ((config.workflow?.library ?? true)) {
      const { seedLibrary } = await import(importUrl(join(llmgodDir, 'overdrive', 'workflow-library.mjs')));
      seedLibrary(join(homedir(), '.claude', 'workflows'), { existsSync, mkdirSync, writeFileSync });
    }
  } catch {}
```

(`existsSync`, `mkdirSync`, `writeFileSync`, `homedir`, `join` are already required at the top of the wrapper — verified at `install.sh:1088-1090`.)

- [ ] **Step 6: Regenerate the embedded module block**

Run: `node scripts/embed-overdrive.mjs`
Expected output: `embedded 8 modules into install.sh`

- [ ] **Step 7: Run the drift guard + full suite to verify pass**

Run: `bun test`
Expected: PASS — install-sync embeds all 8 modules and finds both wiring strings; workflow-cli + workflow-library suites green; existing suites unaffected.

- [ ] **Step 8: Commit**

```bash
git add scripts/embed-overdrive.mjs install.sh test/install-sync.test.mjs
git commit -m "feat(workflow): wire llmgod workflow subcommand + library seeding into wrapper"
```

---

### Task 7: End-to-end manual verification

**Files:** none (verification only)

- [ ] **Step 1: Re-embed is idempotent**

Run: `node scripts/embed-overdrive.mjs && git diff --quiet install.sh && echo CLEAN || echo DIRTY`
Expected: `CLEAN` (re-running the embedder produces no diff).

- [ ] **Step 2: Manager runs against a temp HOME**

Run:
```bash
tmp=$(mktemp -d)
HOME=$tmp bun src/overdrive/workflow-cli.mjs new mine
HOME=$tmp bun src/overdrive/workflow-cli.mjs ls
HOME=$tmp bun src/overdrive/workflow-cli.mjs rm mine
```
Expected: `created …/.claude/workflows/mine.js`; `ls` shows `mine [user]`; `rm` removes it. No stack traces.

- [ ] **Step 3: Seeding is never-clobber**

Run:
```bash
tmp=$(mktemp -d); mkdir -p "$tmp/.claude/workflows"; echo "MINE" > "$tmp/.claude/workflows/review.js"
HOME=$tmp bun -e "import('./src/overdrive/workflow-library.mjs').then(m=>{const fs=require('fs');m.seedLibrary(process.env.HOME+'/.claude/workflows',fs);console.log(fs.readFileSync(process.env.HOME+'/.claude/workflows/review.js','utf8'))})"
```
Expected: prints `MINE` (existing user file untouched).

- [ ] **Step 4: Full suite green**

Run: `bun test`
Expected: PASS, 0 failures.

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A && git commit -m "test(workflow): M1 end-to-end verification" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage (M1 = Pillar 1):**
- Library manager `ls/new/rm` → Tasks 1–4. ✓
- `~/.claude/workflows/<name>.js` registry (cli `:8686`) → Tasks 4–6 write/read there. ✓
- Curated starter library, never-clobber → Task 5 + wrapper seeding Task 6. ✓
- `llmgod workflow` argv dispatch sibling of `xray` (`install.sh:1096`) → Task 6. ✓
- `config.workflow.library` gate → Task 6 Step 5. ✓
- Embed + drift guard + parity with existing module pipeline → Task 6. ✓
- Deferred to later milestones (explicitly out of M1): `run`/`save`/`list`/`status`/`resume` (need run discovery / headless launch), Pillar 4 X-ray (needs Pillar 2). ✓ stated in header.

**Placeholder scan:** the only `TODO` strings are inside `scaffoldWorkflow`'s emitted template — intentional end-user scaffold content, not plan gaps. All steps carry complete code/commands.

**Type consistency:** `parseWorkflowMeta(source)→{name,description}|null`; `listWorkflows(dirs,fs)→[{name,description,scope,path}]`; `validName(name)→bool`; `scaffoldWorkflow(name)→string`; `runWorkflowCli({argv,homeDir,cwd,out,err,fs})→number`; `seedLibrary(dir,fs)→string[]`. Signatures match across tasks 1→6. The wrapper passes `{existsSync,mkdirSync,writeFileSync}` to `seedLibrary` — a subset matching its documented `fs` shape. ✓
