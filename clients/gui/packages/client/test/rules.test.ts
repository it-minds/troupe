// The console's reading of a per-tool rule, held to the plane's: every case in the list
// `Troupe.Protocol.PermissionRule`'s own test is held to, read the same way and refused in
// the same words, so a rule the editor accepts is one the plane accepts.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it } from "node:test";
import { checkRuleSet, parseRule, ruleKind, ruleParts } from "../src/index.js";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../../../../..");
const cases = JSON.parse(readFileSync(resolve(repo, "apps/troupe_protocol/test/support/permission_rules.json"), "utf8")) as {
  rules: Array<{ text: string; reads?: string; refused?: string }>;
  sets: Array<{ set: unknown; refused: string[] }>;
};

describe("a per-tool rule, read as the plane reads it", () => {
  it("reads the cases the plane's module is held to", () => {
    assert.ok(cases.rules.length > 20);
    for (const c of cases.rules) {
      const read = parseRule(c.text);
      if (c.reads !== undefined) assert.deepEqual(read.ok && read.rule.text, c.reads, c.text);
      else assert.deepEqual(read.ok ? null : read.reason, c.refused, c.text);
    }
  });

  it("checks a set as the plane checks the enforced set's permissions", () => {
    for (const c of cases.sets) assert.deepEqual(checkRuleSet(c.set), c.refused, JSON.stringify(c.set));
    assert.deepEqual(checkRuleSet(["shell"]), ["permissions is a map of allow, ask and deny, each a list of rules such as shell(git push)"]);
  });

  it("says what a tool's pattern is, and splits a rule back into its fields", () => {
    assert.equal(ruleKind("shell"), "command");
    assert.equal(ruleKind("grep"), "path");
    assert.equal(ruleKind("mcp"), "mcp");
    assert.equal(ruleKind("web_fetch"), null);
    assert.deepEqual(ruleParts("shell(git push)"), { tool: "shell", pattern: "git push" });
    assert.deepEqual(ruleParts("web_fetch"), { tool: "web_fetch", pattern: "" });
    assert.deepEqual(ruleParts("read_file(a(b).txt)"), { tool: "read_file", pattern: "a(b).txt" });
  });
});
