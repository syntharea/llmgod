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
