// The guard `support/image-reads.ts` puts on every test file here: what a test reads from
// outside `clients/gui` is what the GUI's image build is given. Its reading of the
// Dockerfile and of the root's `.dockerignore`, and a file read past it that fails.

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { copiedByImage, imageCanRead, keptByDockerignore } from "./support/image-reads.js";

const client = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const gui = resolve(client, "../..");
const dockerignorePath = resolve(gui, "../../.dockerignore");
// The image has no `.dockerignore`, and needs none: this is the checkout's question.
const inCheckout = existsSync(dockerignorePath);

describe("what the GUI's image is given from the repository's root", { skip: !inCheckout }, () => {
  it("is what the Dockerfile copies and the root's .dockerignore keeps", () => {
    const copied = copiedByImage(readFileSync(resolve(gui, "Dockerfile"), "utf8"));
    const dockerignore = readFileSync(dockerignorePath, "utf8");
    assert.ok(copied.includes("PROTOCOL.md"));
    assert.equal(imageCanRead("PROTOCOL.md", copied, dockerignore), true);
    assert.equal(imageCanRead("apps/troupe_protocol/test/support/permission_rules.json", copied, dockerignore), true);
    // Copied by nothing, or copied and left out of the context: the two ways #728 failed.
    assert.equal(imageCanRead("test/fixtures/approvals/approved.jsonl", copied, dockerignore), false);
    assert.equal(imageCanRead("apps/troupe_protocol/test/support/policy.json", [...copied, "apps/troupe_protocol/test/support/policy.json"], dockerignore), false);
  });

  it("reads .dockerignore's last matching line as the one that decides", () => {
    const rules = "test\napps/*/test\n!apps/a/test/keep.json\n*.md\n!PROTOCOL.md\n";
    assert.equal(keptByDockerignore(rules, "apps/a/test/keep.json"), true);
    assert.equal(keptByDockerignore(rules, "apps/a/test/other.json"), false);
    assert.equal(keptByDockerignore(rules, "test/fixtures/x"), false);
    assert.equal(keptByDockerignore(rules, "README.md"), false);
    assert.equal(keptByDockerignore(rules, "docs/README.md"), true);
    assert.equal(keptByDockerignore(rules, "PROTOCOL.md"), true);
  });

  it("fails a test file that reads what the image is not given, naming it", () => {
    const run = spawnSync(
      process.execPath,
      ["--import", "tsx", "--import", "./test/support/image-reads.ts", "-e", `require("node:fs").readFileSync(${JSON.stringify(resolve(gui, "../../README.md"))})`],
      { cwd: client, encoding: "utf8" },
    );
    assert.equal(run.status, 1, run.stderr);
    assert.match(run.stderr, /is not given[\s\S]*README\.md/);
  });
});
