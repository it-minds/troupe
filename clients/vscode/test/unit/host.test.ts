import assert from "node:assert/strict";
import { test } from "node:test";
import { INSTALL_URL, machineName, missingMessage } from "../../src/host.js";

test("the machine is the one the terminal runs on, named as VS Code's remote indicator names it", () => {
  assert.equal(machineName(undefined, {}, "laptop"), "on this computer");
  assert.equal(machineName("wsl", { WSL_DISTRO_NAME: "Ubuntu" }, "laptop"), "in WSL: Ubuntu");
  assert.equal(machineName("ssh-remote", {}, "build-box"), "on SSH: build-box");
  assert.equal(machineName("dev-container", {}, "3f2a"), "in the container 3f2a");
  assert.equal(machineName("codespaces", {}, "cs"), "in this codespace");
  assert.equal(machineName("tunnel", {}, "desk"), "on tunnel: desk");
});

test("a missing troupe is one sentence that says where", () => {
  const sentences = [
    missingMessage({ missing: "path" }, "on this computer"),
    missingMessage({ missing: "path" }, "in WSL: Ubuntu"),
    missingMessage({ missing: "setting", setting: "/opt/troupe" }, "on SSH: build-box"),
  ];

  assert.equal(sentences[0], "Troupe isn't installed on this computer (no troupe on the PATH, nor where the installer puts it).");
  assert.equal(sentences[1], "Troupe isn't installed in WSL: Ubuntu (no troupe on the PATH, nor where the installer puts it).");
  assert.equal(sentences[2], "There is no troupe to run at /opt/troupe, which troupe.path names, on SSH: build-box.");

  for (const s of sentences) assert.match(s, /^[A-Z](?:[^.\n]|\.(?! ))*\.$/);
});

test("the link is the install instructions on the documentation site", () => {
  assert.equal(INSTALL_URL, "https://it-minds.github.io/troupe/quick-start/#1-install");
});
