// Tools and skills: your own servers set up by hand, brought in from another app's file,
// given a missing secret, and edited, and how they stand in a session on this computer.
// The daemon is the fake the client's own tests use, over a real socket, so what is
// asserted is what the screen sent the daemon and what it says, and that no value meant
// for the keychain is ever on the screen or in what is written to a file.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient } from "@troupe/client";
import { ConnectScreen } from "../src/views/ConnectScreen";
import { SessionServers } from "../src/views/SessionServers";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, sees, seesButton, type, waitFor } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let client: DaemonClient;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  client.disconnect();
  await daemon.stop();
});

function field<T extends HTMLInputElement | HTMLTextAreaElement = HTMLInputElement>(label: string): T {
  const found = document.querySelector<T>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`no field labelled ${label}`);
  return found;
}

function rowOf(name: string): HTMLLIElement | undefined {
  return [...document.querySelectorAll<HTMLLIElement>("li.cx-row")].find((r) => r.querySelector("h3")?.textContent === name);
}

const SETTINGS = "/home/ada/.config/troupe/mcp.json";

describe("tools and skills", () => {
  it("sets a server up by hand: tried first, the command line split, a secret into the keychain", async () => {
    unmount = render(<ConnectScreen client={client} />).unmount;
    await sees("No servers yet");

    (await seesButton("Set one up by hand")).click();
    await waitFor(() => document.querySelector('aside[aria-label="Set up a server by hand"]'), "the drawer");
    type(field("Name"), "fs");
    type(field<HTMLTextAreaElement>("Command"), "npx -y @modelcontextprotocol/server-filesystem '/home/ada/My Documents'");
    type(field<HTMLTextAreaElement>("Secrets and settings"), "TOKEN=hunter2\nLOG={env:LOG_LEVEL}");

    (await seesButton("Try it first")).click();
    await sees("It started and offered 1 tool: greet. Nothing is kept until you add it.");
    expect(daemon.written).toEqual([]);

    (await seesButton("Add server")).click();
    await sees("Added fs. TOKEN kept in your keychain. Ready, 1 tool.");
    // The file gets the command, its arguments and the variable read from the environment;
    // the key goes to the keychain, and the entry points to it.
    expect(daemon.written).toEqual([
      { name: "fs", scope: "user", server: { command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/ada/My Documents"], env: { LOG: "{env:LOG_LEVEL}" } } },
    ]);
    expect(daemon.keychain).toEqual({ "fs/TOKEN": "hunter2" });
    expect(daemon.servers.find((x) => x.name === "fs")!.env).toEqual({ LOG: "{env:LOG_LEVEL}", TOKEN: "{secret:fs/TOKEN}" });

    const row = await waitFor(() => rowOf("fs"), "the server's row");
    await waitFor(() => row.textContent?.includes("Ready"), "the row ready");
    expect(row.textContent).toContain("RUNS HERE");
    expect(row.textContent).toContain("EVERY PROJECT");
    expect(row.textContent).toContain("IN YOUR SETTINGS");
    expect(document.body.textContent).not.toContain("hunter2");
  });

  it("asks for a missing secret in the row, keeps it in the keychain, and says what the server can do", async () => {
    daemon.servers.push({
      name: "tracker",
      layer: "user",
      source: SETTINGS,
      command: "tracker-mcp",
      args: [],
      env: { API_KEY: "{secret:tracker/API_KEY}" },
      tools: [
        { name: "search_issues", description: "Finds issues by text. And more.", schema: {}, ...({ title: "Search issues", read_only: true } as object) },
        { name: "create_issue", description: "Opens a new issue.", schema: {} },
      ],
    });
    unmount = render(<ConnectScreen client={client} />).unmount;
    const row = await waitFor(() => rowOf("tracker"), "the row");
    await waitFor(() => row.textContent?.includes("Needs a secret"), "the row's standing");
    expect(row.textContent).toContain("API_KEY is not set");

    (await seesButton("Add API_KEY", row)).click();
    const secret = await waitFor(() => document.querySelector<HTMLInputElement>('[aria-label="Value for API_KEY"]'), "the secret's field");
    expect(secret.type).toBe("password");
    type(secret, "s3cr3t");
    (await seesButton("Save and check", row)).click();
    await sees("Kept API_KEY in your keychain.");
    expect(daemon.keychain).toEqual({ "tracker/API_KEY": "s3cr3t" });
    expect(document.body.textContent).not.toContain("s3cr3t");

    await waitFor(() => row.textContent?.includes("Ready") && row.textContent.includes("2 tools available"), "the row ready");
    await waitFor(() => row.textContent?.includes("Search issues"), "the tools as the server describes them");
    expect(row.textContent).toContain("Finds issues by text.");
    expect(row.textContent).not.toContain("And more.");
    expect(row.textContent).toContain("READS ONLY");
    expect(row.textContent).toContain("Create issue");
    expect(row.textContent).toContain("CHANGES THINGS");

    (await seesButton("Technical", row)).click();
    await waitFor(() => row.textContent?.includes("● IN KEYCHAIN"), "the key as kept");
    expect(row.textContent).toContain("mcp.tracker.search_issues");
  });

  it("edits a server: a key taken out is forgotten in the keychain, a new one kept there", async () => {
    daemon.servers.push({ name: "t", layer: "user", source: SETTINGS, command: "t-mcp", args: [], env: { A: "{secret:t/A}", B: "{secret:t/B}" } });
    daemon.keychain = { "t/A": "one", "t/B": "two" };
    unmount = render(<ConnectScreen client={client} />).unmount;
    const row = await waitFor(() => rowOf("t"), "the row");
    (await seesButton("Details", row)).click();
    (await seesButton("Edit", row)).click();
    const secrets = await waitFor(() => document.querySelector<HTMLTextAreaElement>('[aria-label="Secrets and settings"]'), "the drawer");
    expect(secrets.value).toBe("A\nB");
    expect(field("Name").disabled).toBe(true); // at once: the drawer was waited for above

    type(secrets, "A\nC=three");
    (await seesButton("Save")).click();
    await sees("Saved t. C kept in your keychain.");
    expect(daemon.keychain).toEqual({ "t/A": "one", "t/C": "three" });
    expect(daemon.servers.find((x) => x.name === "t")!.env).toEqual({ A: "{secret:t/A}", C: "{secret:t/C}" });
  });

  it("brings servers in from another app's file, following it", async () => {
    daemon.importable["~/.cursor/mcp.json"] = { servers: { sentry: { url: "https://mcp.sentry.dev/mcp" } } };
    unmount = render(<ConnectScreen client={client} />).unmount;
    (await seesButton("Bring in from another app")).click();
    const cursor = await waitFor(() => [...document.querySelectorAll("label.cx-source-item")].find((l) => l.textContent?.includes("Cursor")), "Cursor's file");
    cursor.querySelector("input")!.click();
    (await seesButton("Bring them in")).click();
    await sees("Added sentry, following ~/.cursor/mcp.json. Checking them now.");
    const call = daemon.calls.find((c) => c.method === "mcp.add")!;
    expect(call.params).toMatchObject({ from: "~/.cursor/mcp.json", link: true, scope: "user" });
    const row = await waitFor(() => rowOf("sentry"), "the row");
    expect(row.textContent).toContain("REMOTE");
    expect(row.textContent).toContain("↻ FOLLOWS");
  });

  it("signs in to a server that acts as you, from its row", async () => {
    daemon.servers.push({ name: "notes", layer: "user", source: SETTINGS, url: "https://mcp.example.test/notes", oauth: { client_id: "troupe-test-client" } });
    const before = globalThis.open;
    const opened: string[] = [];
    globalThis.open = ((url: string) => {
      opened.push(url);
      return null;
    }) as typeof globalThis.open;
    try {
      unmount = render(<ConnectScreen client={client} />).unmount;
      const row = await waitFor(() => rowOf("notes"), "the row");
      await waitFor(() => row.textContent?.includes("Needs you to sign in"), "its standing");
      (await seesButton("Sign in", row)).click();
      await sees("notes: finish signing in in your browser.");
      expect(opened).toEqual([expect.stringContaining("https://login.example.test/tenant/authorize?")]);
      daemon.finishSignIn("notes");
      await waitFor(() => row.textContent?.includes("as ada@example.test") || row.textContent?.includes("Not checked yet"), "signed in", 5000);
    } finally {
      globalThis.open = before;
    }
  });

  it("finds another app's skills and uses that folder", async () => {
    daemon.foundSkills = [
      {
        app: "Claude Code",
        dir: "~/.claude/skills",
        from: "/home/ada/.claude/skills",
        scope: "user",
        state: "available",
        skills: [{ name: "review", description: "How I review" }],
      },
    ];
    daemon.importable["/home/ada/.claude/skills"] = { skills: [{ name: "review", description: "How I review" }] };
    unmount = render(<ConnectScreen client={client} />).unmount;
    (await seesButton("Skills")).click();
    await sees("Claude Code skills");
    (await seesButton("Use this folder")).click();
    await sees("Using 1 skills from ~/.claude/skills.");
    const call = daemon.calls.find((c) => c.method === "skills.add")!;
    expect(call.params).toMatchObject({ from: "/home/ada/.claude/skills", link: true, scope: "user" });
  });

  it("says what is wrong before anything is sent", async () => {
    unmount = render(<ConnectScreen client={client} />).unmount;
    (await seesButton("Set one up by hand")).click();
    await waitFor(() => document.querySelector('aside[aria-label="Set up a server by hand"]'), "the drawer");
    type(field("Name"), "Bad.Name");
    await sees("A name is lower-case letters");
    expect((await seesButton("Add server")).disabled).toBe(true);
    expect((await seesButton("Try it first")).disabled).toBe(true);
  });
});

describe("a session's servers", () => {
  it("says how each stands in the session, starts one added since, and signs in to one that wants you", async () => {
    daemon.servers.push(
      { name: "fs", layer: "user", source: "/home/ada/.config/troupe/mcp.json", command: "npx", args: ["fs"] },
      { name: "notes", layer: "user", source: "/home/ada/.config/troupe/mcp.json", url: "https://mcp.example.test/notes", oauth: { client_id: "troupe-test-client" } },
    );
    const before = globalThis.open;
    const opened: string[] = [];
    globalThis.open = ((url: string) => {
      opened.push(url);
      return null;
    }) as typeof globalThis.open;
    let managed = 0;
    try {
      unmount = render(<SessionServers daemon={client} sessionId="s-1" workspace="/home/ada/project" onManage={() => managed++} />).unmount;
      const line = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Your servers in this session"]'), "the servers line");
      await waitFor(() => line.textContent?.includes("✓ fs") && line.textContent.includes("→ notes"), "each server's glyph");
      expect(line.textContent).toContain("(1 need you)");
      const listed = daemon.calls.find((c) => c.method === "mcp.list")!;
      expect(listed.params).toMatchObject({ session_id: "s-1", workspace: "/home/ada/project" });

      (await seesButton("Servers:", line)).click();
      await sees("sign in");
      const notes = [...line.querySelectorAll("li")].find((li) => li.textContent?.includes("notes"))!;
      button("Sign in", notes)!.click();
      await sees("notes: finish signing in in your browser");
      expect(opened).toEqual([expect.stringContaining("https://login.example.test/")]);

      // The sign-in's line shows before the list is read again, and its buttons wait for that.
      const fs = [...line.querySelectorAll("li")].find((li) => li.textContent?.includes("fs"))!;
      (await waitFor(() => {
        const restart = button("Restart", fs);
        return restart && !restart.disabled ? restart : null;
      }, "Restart, once the sign-in is done")).click();
      await sees("fs: ready, 1 tools");
      const restarted = daemon.calls.filter((c) => c.method === "mcp.check").at(-1)!;
      expect(restarted.params).toMatchObject({ session_id: "s-1", name: "fs" });

      button("Add or change servers on Tools and skills", line)!.click();
      expect(managed).toBe(1);
    } finally {
      globalThis.open = before;
    }
  });

  it("shows nothing for a session with no servers of yours", async () => {
    unmount = render(<SessionServers daemon={client} sessionId="s-1" workspace={null} />).unmount;
    await waitFor(() => daemon.calls.some((c) => c.method === "mcp.list"), "the listing");
    expect(document.querySelector('[aria-label="Your servers in this session"]')).toBeNull();
  });
});
