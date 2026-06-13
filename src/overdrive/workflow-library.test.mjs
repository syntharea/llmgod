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

test("seedLibrary writes a starter when absent and mkdirs a missing dir", () => {
  const store = {}; // dir does not exist yet, no files
  let madeDir = false;
  const fs = {
    existsSync: (p) => p in store || (store["/wf"] && p.startsWith("/wf/") && p.slice(4) in store["/wf"]),
    mkdirSync: (p) => { madeDir = true; store[p] = {}; },
    writeFileSync: (p, c) => { (store["/wf"] ??= {})[p.slice(4)] = c; },
  };
  const seeded = seedLibrary("/wf", fs);
  expect(madeDir).toBe(true);                              // missing dir created
  expect(seeded).toContain("review");                     // absent starter written
  expect(store["/wf"]["review.js"]).toContain("name: 'review'");
});
