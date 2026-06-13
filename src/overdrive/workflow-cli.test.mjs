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
