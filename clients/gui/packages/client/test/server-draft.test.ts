// One of your own servers as the desktop app's form edits it: a new one is written whole,
// an edit sends only what changed (the daemon merges it as RFC 7396 does), a value the
// file keeps is never sent and never lost, and a try says what it cannot carry.

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { draftOf, draftProblems, joinCommand, pairsFromText, pairsToText, serverChanges, serverPatch, serverTrial, splitCommand } from "../src/index.js";
import type { LocalServer } from "../src/index.js";

const listed = (over: Partial<LocalServer>): LocalServer => ({ name: "x", layer: "user", source: "/home/ada/.config/troupe/mcp.json", state: null, tools: [], error: null, ...over });

describe("a server as the form edits it", () => {
  it("writes a new local server whole, one argument a line", () => {
    const draft = { ...draftOf(), name: "fs", command: "npx", args: "-y\n@modelcontextprotocol/server-filesystem\n/home/ada/My Documents", env: [{ key: "TOKEN", value: "{env:FS_TOKEN}", kept: false }] };
    assert.deepEqual(draftProblems(draft), []);
    assert.deepEqual(serverPatch(draft), {
      command: "npx",
      args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/ada/My Documents"],
      env: { TOKEN: "{env:FS_TOKEN}" },
    });
  });

  it("writes a remote server with a sign-in that introduces itself as an empty oauth", () => {
    const draft = { ...draftOf(), name: "wiki", transport: "http" as const, url: "https://mcp.example.test/mcp", oauth: { clientId: "", scopes: "", issuer: "", redirectUri: "", resource: true } };
    assert.deepEqual(serverPatch(draft), { url: "https://mcp.example.test/mcp", oauth: {} });
  });

  it("sends an edit as what changed, leaves kept values out, and takes a removed one out with null", () => {
    const server = listed({ name: "fs", transport: "stdio", command: "npx", args: ["fs"], env: ["A", "B"], permission: "ask" });
    const draft = draftOf(server);
    assert.deepEqual(serverPatch(draft, server), {}, "nothing changed, nothing sent");

    draft.env = [draft.env[0]!, { key: "C", value: "{env:C}", kept: false }];
    draft.permission = "auto";
    assert.deepEqual(serverPatch(draft, server), { permission: "auto", env: { B: null, C: "{env:C}" } });

    draft.env[0] = { ...draft.env[0]!, value: "new" };
    assert.deepEqual((serverPatch(draft, server)["env"] as Record<string, unknown>)["A"], "new");
  });

  it("changes transport by taking the other's keys out", () => {
    const server = listed({ name: "t", transport: "stdio", command: "t-server", args: ["--x"], env: ["T"] });
    const draft = { ...draftOf(server), transport: "http" as const, url: "https://t.example.test/mcp", headers: [{ key: "Authorization", value: "Bearer {env:T}", kept: false }] };
    assert.deepEqual(serverPatch(draft, server), { command: null, args: null, env: null, url: "https://t.example.test/mcp", headers: { Authorization: "Bearer {env:T}" } });
  });

  it("edits a sign-in key by key, and turns the resource indicator off as false", () => {
    const server = listed({ name: "w", transport: "http", url: "https://w.example.test", oauth: { client_id: "abc", scopes: ["read"] } });
    const draft = draftOf(server);
    draft.oauth = { ...draft.oauth!, scopes: "read write", resource: false };
    assert.deepEqual(serverPatch(draft, server), { oauth: { scopes: ["read", "write"], resource: false } });
    draft.oauth = null;
    assert.deepEqual(serverPatch(draft, server), { oauth: null });
  });

  it("marks where the organisation keeps files, and leaves the default timeout out", () => {
    const server = listed({ name: "d", transport: "http", url: "https://d.example.test", timeout_ms: 30_000 });
    const draft = { ...draftOf(server), storesFiles: true, files: "upload_document, save" };
    assert.equal(draft.timeoutMs, "");
    assert.deepEqual(serverPatch(draft, server), { stores: "files", files: ["upload_document", "save"] });
  });

  it("says what a try cannot carry: the values the file keeps", () => {
    const server = listed({ name: "t", transport: "http", url: "https://t.example.test", headers: ["Authorization", "X-Team"] });
    const draft = draftOf(server);
    draft.headers[1] = { ...draft.headers[1]!, value: "core" };
    assert.deepEqual(serverTrial(draft), { server: { url: "https://t.example.test", headers: { "X-Team": "core" } }, kept: ["Authorization"] });
  });

  it("names what is wrong before anything is sent", () => {
    assert.deepEqual(draftProblems({ ...draftOf(), name: "Bad.Name" }), [
      "A name is lower-case letters, digits, - and _, starting with a letter or a digit.",
      "A local server needs the command that starts it.",
    ]);
    const http = { ...draftOf(), name: "h", transport: "http" as const, url: "ftp://x", headers: [{ key: "A", value: "", kept: false }, { key: "A", value: "1", kept: false }] };
    assert.equal(draftProblems(http).length, 3);
  });

  it("splits a pasted command line as a shell does, and joins one back so it splits the same", () => {
    assert.deepEqual(splitCommand(`npx -y "@scope/server" '/home/ada/My Documents' a\\ b ""`), ["npx", "-y", "@scope/server", "/home/ada/My Documents", "a b", ""]);
    const words = ["node", "/srv/it's here/index.js", "--flag"];
    assert.deepEqual(splitCommand(joinCommand(words[0]!, words.slice(1))), words);
  });

  it("reads secrets' lines: a key the server has alone on its line keeps its value", () => {
    const had = draftOf(listed({ name: "t", env: ["A"], secrets: ["A"] })).env;
    assert.equal(pairsToText(had), "A");
    assert.deepEqual(pairsFromText("A\nB=two", had), [
      { key: "A", value: "", kept: true, keychain: true, missing: false },
      { key: "B", value: "two", kept: false },
    ]);
  });

  it("sends a typed value to the keychain, and one that reads the environment to the file", () => {
    const draft = { ...draftOf(), name: "fs", command: "npx", env: [{ key: "TOKEN", value: "hunter2", kept: false }, { key: "LOG", value: "{env:LOG_LEVEL}", kept: false }] };
    assert.deepEqual(serverChanges(draft), {
      patch: { command: "npx", args: [], env: { LOG: "{env:LOG_LEVEL}" } },
      secrets: [{ field: "env", key: "TOKEN", value: "hunter2" }],
    });
  });

  it("replaces a kept secret without touching the entry, and forgets one taken out", () => {
    const server = listed({ name: "t", transport: "stdio", command: "t", args: [], env: ["A", "B"], secrets: ["A", "B"] });
    const draft = { ...draftOf(server), env: [{ key: "A", value: "new", kept: true }] };
    assert.deepEqual(serverChanges(draft, server), {
      patch: { env: { B: null } },
      secrets: [
        { field: "env", key: "A", value: "new" },
        { field: "env", key: "B", value: null },
      ],
    });
  });

  it("forgets every kept secret of a transport left behind", () => {
    const server = listed({ name: "t", transport: "stdio", command: "t", args: [], env: ["A"], secrets: ["A"] });
    const draft = { ...draftOf(server), transport: "http" as const, url: "https://t.example.test/mcp" };
    const { patch, secrets } = serverChanges(draft, server);
    assert.equal(patch["env"], null);
    assert.deepEqual(secrets, [{ field: "env", key: "A", value: null }]);
  });
});
