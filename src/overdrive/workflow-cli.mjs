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
