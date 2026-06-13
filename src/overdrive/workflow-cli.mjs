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
