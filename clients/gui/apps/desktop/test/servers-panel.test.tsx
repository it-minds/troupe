// The "Servers and skills" panel on This computer (troupe-remote Decision 700): a
// `.mcp.json` typed into the import field shows up as a row with its layer, a check
// says what the server offered, a skills directory linked shows up beside it, and
// Remove takes a row away. The daemon is the fake the client's own tests use, over a
// real socket, so what is asserted is the page's traffic and words, not its functions.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { DaemonClient } from "@troupe/client";
import { Servers } from "../src/views/Servers";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, render, says, type, waitFor } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let client: DaemonClient;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  daemon.importable["/home/ada/.claude/.mcp.json"] = { servers: { fs: { command: "npx", args: ["fs"], env: { TOKEN: "hunter2" } } } };
  daemon.importable["/home/ada/.claude/skills"] = { skills: [{ name: "review", description: "How I review" }] };
  client = new DaemonClient({ transport: "ws", port: daemon.port, token: daemon.token });
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  client.disconnect();
  await daemon.stop();
});

/** The input labelled `label`, by its accessible name. */
function field(label: string): HTMLInputElement {
  const found = document.querySelector<HTMLInputElement>(`input[aria-label="${label}"]`);
  if (!found) throw new Error(`no field labelled ${label}`);
  return found;
}

describe("the servers and skills panel", () => {
  it("imports a .mcp.json, checks the server, links a skills directory, and removes both", async () => {
    unmount = render(<Servers client={client} />).unmount;
    await waitFor(() => says("No servers yet"), "the empty panel");

    type(field("File to import"), "/home/ada/.claude/.mcp.json");
    button("Import servers")!.click();
    await waitFor(() => says("Imported fs into /home/ada/.config/troupe/mcp.json"), "the import's outcome");
    const row = await waitFor(() => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("fs")), "the server's row");
    expect(row.textContent).toContain("user");
    expect(row.textContent).toContain("npx fs");
    expect(row.textContent).toContain("Not checked");
    expect(document.body.textContent).not.toContain("hunter2");

    button("Check", row)!.click();
    await waitFor(() => says("fs: ready, 1 tools"), "the check's outcome");
    expect(row.textContent).toContain("Ready");
    expect(row.textContent).toContain("greet");

    type(field("Directory of skills"), "/home/ada/.claude/skills");
    button("Link skills")!.click();
    await waitFor(() => says("Linked review into /home/ada/.config/troupe/skills.json"), "the link's outcome");
    const skill = await waitFor(() => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("How I review")), "the skill's row");
    expect(skill.textContent).toContain("(linked)");

    // A linked skill is not the layer's to delete, and the panel says where it comes from.
    button("Remove", skill)!.click();
    await waitFor(() => says("comes from /home/ada/.claude/skills"), "the refusal");

    const serverRow = [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("npx fs"))!;
    button("Remove", serverRow)!.click();
    await waitFor(() => says("Removed fs from /home/ada/.config/troupe/mcp.json"), "the removal");
    await waitFor(() => says("No servers yet"), "the empty table again");

    // Every request went to the daemon's seven methods and nothing else was asked of it.
    const methods = new Set(daemon.calls.map((c) => c.method));
    expect([...methods].filter((m) => m.startsWith("mcp.") || m.startsWith("skills.")).sort()).toEqual(["mcp.add", "mcp.check", "mcp.list", "mcp.remove", "skills.add", "skills.list", "skills.remove"]);
  });

  // troupe Decision 822: a skill in the repository's `.agents/skills` is read in place and
  // never written, so Remove says whose it is rather than asking the daemon to take it out
  // of your own files; one a nearer layer hides is listed with why.
  it("names the .agents layer, lists a hidden skill with why, and leaves the repository's skill alone", async () => {
    const agents = "/home/ada/project/.agents/skills";
    daemon.skills.push({ name: "lint", description: "The repository's lint", layer: "agents", source: agents, dir: `${agents}/lint`, linked: false });
    daemon.skippedSkills.push({
      name: "review",
      layer: "agents",
      source: agents,
      dir: `${agents}/review`,
      linked: false,
      status: "skipped",
      reason: "skipped: /home/ada/project/.troupe/skills/review is used",
    });

    unmount = render(<Servers client={client} />).unmount;
    await waitFor(() => says("No servers yet"), "the panel");
    type(document.querySelector<HTMLInputElement>('input[placeholder="/home/me/project (optional)"]')!, "/home/ada/project");
    const skill = await waitFor(() => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("The repository's lint")), "the skill's row");
    expect(skill.textContent).toContain("agents");

    button("Remove", skill)!.click();
    await waitFor(() => says("lint is the repository's"), "the refusal");
    expect(document.body.textContent).not.toContain("no skill named");
    expect(daemon.calls.some((c) => c.method === "skills.remove")).toBe(false);

    const hidden = await waitFor(() => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("/home/ada/project/.troupe/skills/review is used")), "the hidden skill's row");
    expect(hidden.textContent).toContain("review");
    expect(button("Remove", hidden)).toBeFalsy();
  });

  // troupe-remote Decision 741: a server that wants you signed in.
  it("signs in to a server that wants you, opens the browser, and says whose the sign-in is", async () => {
    daemon.servers.push({
      name: "notes",
      layer: "user",
      source: "/home/ada/.config/troupe/mcp.json",
      url: "https://mcp.example.test/mcp",
      oauth: { client_id: "troupe-test-client" },
    });
    const opened: string[] = [];
    const before = globalThis.open;
    globalThis.open = ((url: string) => {
      opened.push(url);
      return null;
    }) as typeof globalThis.open;

    try {
      unmount = render(<Servers client={client} />).unmount;
      const row = await waitFor(() => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("notes")), "the server's row");
      expect(row.textContent).toContain("Not signed in");

      button("Check", row)!.click();
      await waitFor(() => row.textContent?.includes("Needs sign-in"), "the check says it waits for a sign-in");

      button("Sign in", row)!.click();
      await waitFor(() => says("notes: finish signing in in your browser"), "the sign-in's outcome");
      expect(opened).toEqual([expect.stringContaining("https://login.example.test/tenant/authorize?")]);
      await waitFor(() => says("Waiting for the browser"), "the row waits for the browser");
      expect(document.body.textContent).toContain("Open the sign-in page for notes");

      // The person finishes in the browser; the panel reads it again by itself.
      daemon.finishSignIn("notes");
      const signedIn = await waitFor(
        () => [...document.querySelectorAll("tr")].find((r) => r.textContent?.includes("Signed in as ada@example.test")),
        "the row says whose the sign-in is",
        5000,
      );
      expect(button("Sign in", signedIn)).toBeFalsy();

      button("Sign out", signedIn)!.click();
      await waitFor(() => says("notes: signed out on this computer"), "the sign-out's outcome");
      await waitFor(() => says("Not signed in"), "the row is signed out again");

      const calls = daemon.calls.filter((c) => c.method === "mcp.sign_in" || c.method === "mcp.sign_out");
      expect(calls.map((c) => c.method)).toEqual(["mcp.sign_in", "mcp.sign_out"]);
      expect(calls.every((c) => String(c.params["command_id"]).startsWith("c-"))).toBe(true);
    } finally {
      globalThis.open = before;
    }
  });
});
