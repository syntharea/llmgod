// src/overdrive/workflow-cli.test.mjs
import { test, expect } from "bun:test";
import { parseWorkflowMeta, listWorkflows, scaffoldWorkflow, validName, runWorkflowCli } from "./workflow-cli.mjs";

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

test("ls on an empty library prints the no-workflows hint and returns 0", () => {
  const h = harness({});
  expect(h.code(["ls"])).toBe(0);
  expect(h.out()).toContain("no workflows");
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
