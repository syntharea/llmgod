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
