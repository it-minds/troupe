// A session's instructions as layers (troupe #55): `context.get`'s files in the order the
// prompt reads them, each memory document named with its version and where it came from,
// each file with its path, and a file found and not read still listed, saying why.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { instructionLayers } from "../src/index.js";
import type { InstructionsContext } from "../src/index.js";

const file = (scope: string, path: string, extra: Record<string, unknown> = {}) => ({
  scope,
  path,
  size: 10,
  chars: 10,
  budget: 16000,
  status: "whole",
  hash: "sha256:0123456789abcdef",
  ...extra,
});

describe("instructionLayers", () => {
  it("lists every layer in order: organisation, team, profile, your own, the repository's, the brief", () => {
    const context: InstructionsContext = {
      budget: 16000,
      used: 40,
      memory_from: { source: "https://plane.example.test", fetched_at: "2026-10-23T09:00:00Z" },
      files: [
        file("organisation", "memory:organisation", { version: 3, label: "the organisation's memory", budget: 8192 }),
        file("team", "memory:team/design", { version: 5, name: "design", label: "the team design's memory", budget: 8192 }),
        file("profile", "memory:profile/dev", { version: 1, name: "dev", label: "the worker profile dev's memory", budget: 8192 }),
        file("user", "/home/me/.config/troupe/AGENTS.md"),
        file("root", "/home/me/project/AGENTS.md"),
        file("root", "/home/me/project/CLAUDE.md", { status: "skipped", reason: "not read: run troupe onboard", hash: null }),
        file("brief", "/home/me/project/.troupe/memory.md", { status: "absent", hash: null }),
      ],
    };

    const rows = instructionLayers(context);

    assert.deepEqual(
      rows.map((r) => [r.heading, r.what, r.version]),
      [
        ["Organisation", "the organisation's memory", "version 3"],
        ["Team", "the team design's memory", "version 5"],
        ["Worker profile", "the worker profile dev's memory", "version 1"],
        ["Your own", "/home/me/.config/troupe/AGENTS.md", "01234567"],
        ["Repository", "/home/me/project/AGENTS.md", "01234567"],
        ["Repository", "/home/me/project/CLAUDE.md", ""],
        ["Project brief", "/home/me/project/.troupe/memory.md", ""],
      ],
    );

    assert.equal(rows[0]?.source, "https://plane.example.test, fetched 2026-10-23T09:00:00Z");
    assert.equal(rows[3]?.source, "your config directory, on this machine");
    assert.deepEqual(
      rows.map((r) => r.inForce),
      [true, true, true, true, true, false, false],
    );
    assert.equal(rows[5]?.note, "not read: run troupe onboard");
  });

  it("names a pod's memory as the activation's", () => {
    const rows = instructionLayers({
      budget: 16000,
      used: 0,
      memory_from: { source: "the plane, with the session's activation", fetched_at: null },
      files: [file("profile", "memory:profile/fixing", { version: 2, label: "the worker profile fixing's memory" })],
    });

    assert.equal(rows[0]?.source, "the plane, with the session's activation");
  });

  // #55's user level: the person's own memory from the plane, after the organisation's,
  // before their own file, named as theirs with its version.
  it("lists the person's own memory after the organisation's and before their own file", () => {
    const rows = instructionLayers({
      budget: 16000,
      used: 10,
      memory_from: { source: "https://plane.example.test", fetched_at: "2026-10-25T09:00:00Z" },
      files: [
        file("organisation", "memory:organisation", { version: 3, label: "the organisation's memory" }),
        file("person", "memory:user", { version: 2, label: "your own memory" }),
        file("user", "/home/me/.config/troupe/AGENTS.md"),
      ],
    });

    assert.deepEqual(
      rows.map((r) => [r.layer, r.heading, r.what, r.version]),
      [
        ["organisation", "Organisation", "the organisation's memory", "version 3"],
        ["person", "Your memory", "your own memory", "version 2"],
        ["yours", "Your own", "/home/me/.config/troupe/AGENTS.md", "01234567"],
      ],
    );
    assert.equal(rows[1]?.source, "https://plane.example.test, fetched 2026-10-25T09:00:00Z");
  });
});
