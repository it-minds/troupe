// Your own MCP servers and skills, through the daemon (troupe-remote Decision 700).
//
// A Claude Code `.mcp.json` and a `~/.claude/skills` come in with one call each, are
// listed with the layer they landed in, a server can be tried before it is kept and
// taken out again, and — the rule that matters — a server's environment comes back as
// the names of its variables and never their values. Every call is a real request to
// the fake daemon, which answers with the daemon's shapes.

import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { DaemonClient } from "../src/index.js";
import { FakeDaemon } from "./support/daemon.js";

describe("your own servers and skills, over the daemon", () => {
  let daemon: FakeDaemon;
  let client: DaemonClient;

  before(async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    daemon.importable["/home/ada/.claude/.mcp.json"] = {
      servers: {
        fs: { command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"], env: { LOG_LEVEL: "debug", TOKEN: "hunter2" } },
        empty: {},
      },
    };
    daemon.importable["/home/ada/.claude/skills"] = { skills: [{ name: "review", description: "How I review" }] };
    client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
  });

  after(async () => {
    client.disconnect();
    await daemon.stop();
  });

  it("imports a .mcp.json in one step and lists it with its layer, env as names only", async () => {
    const imported = await client.importServers({ from: "/home/ada/.claude/.mcp.json" });
    assert.deepEqual(imported.added, ["fs"]);
    assert.deepEqual(imported.skipped, [{ name: "empty", reason: "has neither a command nor a url" }]);
    assert.equal(imported.linked, false);
    assert.equal(imported.path, "/home/ada/.config/troupe/mcp.json");

    // A command, so it carries an id the daemon can deduplicate on.
    const add = daemon.calls.find((c) => c.method === "mcp.add");
    assert.match(String(add?.params["command_id"]), /^c-/);

    const { servers } = await client.listServers();
    assert.equal(servers.length, 1);
    const [fs] = servers;
    assert.equal(fs!.name, "fs");
    assert.equal(fs!.layer, "user");
    assert.equal(fs!.transport, "stdio");
    assert.deepEqual(fs!.env, ["LOG_LEVEL", "TOKEN"]);
    assert.equal(fs!.state, null, "nothing has run it yet");
    assert.equal(JSON.stringify(servers).includes("hunter2"), false);
  });

  it("tries a server before it is kept, and one that is kept", async () => {
    const tried = await client.checkServer({ name: "nope", server: { command: "no-such-mcp-server-anywhere" } });
    assert.equal(tried.server.state, "error");
    assert.match(String(tried.server.error), /could not start/);

    const kept = await client.checkServer({ name: "fs" });
    assert.equal(kept.server.state, "ready");
    assert.deepEqual(kept.server.tools, ["greet"]);
  });

  it("writes a partial entry to disable a server, and removes it", async () => {
    const written = await client.writeServer({ name: "fs", server: { disabled: true } });
    assert.equal(written.entry["disabled"], true);
    assert.deepEqual(written.entry["env"], ["LOG_LEVEL", "TOKEN"], "the entry comes back with names, not values");

    const { servers } = await client.listServers({ session_id: "s-1" });
    assert.equal(servers[0]?.disabled, true);
    assert.equal(servers[0]?.state, "disabled");

    await assert.rejects(client.writeServer({ name: "bad.name", server: { command: "x" } }), /not a server name/);

    const removed = await client.removeServer({ name: "fs" });
    assert.deepEqual(removed.removed, ["fs"]);
    assert.deepEqual((await client.listServers()).servers, []);
    await assert.rejects(client.removeServer({ name: "fs" }), /no server named fs/);
  });

  it("links a skills directory into a workspace, lists it there and not for the user alone, and unlinks it", async () => {
    const linked = await client.importSkills({ scope: "workspace", workspace: "/home/ada/project", from: "/home/ada/.claude/skills", link: true });
    assert.deepEqual(linked.added, ["review"]);
    assert.equal(linked.linked, true);
    assert.equal(linked.path, "/home/ada/project/.troupe/skills.json");

    const { skills } = await client.listSkills("/home/ada/project");
    assert.equal(skills.length, 1);
    assert.equal(skills[0]!.layer, "workspace");
    assert.equal(skills[0]!.linked, true);
    assert.equal(skills[0]!.source, "/home/ada/.claude/skills");
    assert.deepEqual((await client.listSkills()).skills, [], "the user's layer alone has none");

    await assert.rejects(client.removeSkill({ scope: "workspace", workspace: "/home/ada/project", name: "review" }), /comes from/);
    const unlinked = await client.removeSkill({ scope: "workspace", workspace: "/home/ada/project", include: "/home/ada/.claude/skills" });
    assert.deepEqual(unlinked.removed, ["review"]);
    assert.deepEqual((await client.listSkills("/home/ada/project")).skills, []);

    await assert.rejects(client.importSkills({ from: "/nowhere" }), /not a directory/);
    await assert.rejects(client.importSkills({ scope: "workspace", from: "/home/ada/.claude/skills" }), /needs a workspace/);
  });

  // troupe-remote Decision 741: a server that wants you signed in, and how it stands.
  it("signs in to a server that wants you, reads how it stands, and signs out, never seeing a token", async () => {
    daemon.servers.push({ name: "notes", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/mcp", oauth: { client_id: "troupe-test-client" } });
    daemon.servers.push({ name: "plain", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://other.example.test/mcp" });

    const listed = (await client.listServers({ session_id: "s-1" })).servers;
    const notes = listed.find((s) => s.name === "notes")!;
    assert.deepEqual(notes.auth, { state: "signed_out", account: null, error: null });
    assert.equal(notes.oauth?.client_id, "troupe-test-client");
    assert.equal(notes.state, "sign_in", "a session waits for the sign-in");
    assert.equal(listed.find((s) => s.name === "plain")!.auth, null, "a server that takes none has no sign-in");

    const started = await client.signInServer({ name: "notes" });
    assert.equal(started.server, "notes");
    assert.match(started.url, /^https:\/\/login\.example\.test\/tenant\/authorize\?/);
    assert.match(started.redirect_uri, /^http:\/\/127\.0\.0\.1:\d+\/callback$/);
    const call = daemon.calls.find((c) => c.method === "mcp.sign_in");
    assert.match(String(call?.params["command_id"]), /^c-/);
    assert.equal((await client.listServers()).servers.find((s) => s.name === "notes")!.auth?.state, "signing_in");

    daemon.finishSignIn("notes");
    const after = (await client.listServers({ session_id: "s-1" })).servers.find((s) => s.name === "notes")!;
    assert.deepEqual(after.auth, { state: "signed_in", account: "ada@example.test", error: null });
    assert.equal(after.state, "ready");

    const out = await client.signOutServer({ name: "notes" });
    assert.equal(out.auth?.state, "signed_out");
    await assert.rejects(client.signInServer({ name: "plain" }), /takes no sign-in/);
    daemon.servers = daemon.servers.filter((s) => s.name !== "notes" && s.name !== "plain");
  });
});
