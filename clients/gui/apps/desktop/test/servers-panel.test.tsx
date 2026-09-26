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
});
