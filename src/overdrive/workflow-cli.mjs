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
