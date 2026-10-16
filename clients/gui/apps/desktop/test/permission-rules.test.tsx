// troupe #658, from the desktop app's side: the per-tool permission rules a session on this
// computer runs under, shown on This computer with where each came from and never edited,
// and an approval a rule asked for saying which rule and whose.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import type { Entry } from "@troupe/client";
import { App } from "../src/App";
import { ApprovalPanel } from "../src/views/Approval";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { nav, render, says, startOnTheList, waitFor } from "./support";

// jsdom lays nothing out, so it has nothing to scroll; the transcript asks anyway.
Element.prototype.scrollIntoView = function scrollIntoView() {};
// The page's WebSocket: see local-mode.test.tsx.
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon?.stop();
  daemon = null;
});

function rulesPanel(): HTMLElement | null {
  return document.querySelector<HTMLElement>('section[aria-label="Permission rules"]');
}

describe("the permission rules on This computer", () => {
  it("lists every file's rules with where each came from, and why one does not apply", async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    daemon.permissions = [
      { action: "ask", rule: "shell(git push)", tool: "shell", pattern: "git push", scope: "enforced", source: "/etc/troupe/managed.yaml", ignored: null },
      { action: "deny", rule: "read_file(secrets/**)", tool: "read_file", pattern: "secrets/**", scope: "user", source: "/home/ada/.config/troupe/config.yaml", ignored: null },
      { action: "allow", rule: "shell", tool: "shell", pattern: null, scope: "project", source: "/w/.troupe/config.yaml", ignored: "a project's file sets it only in a trusted workspace" },
    ];
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".me"), "the shell");

    nav("This computer")!.click();
    const panel = await waitFor(() => rulesPanel(), "the rules panel");
    await waitFor(() => (panel.textContent ?? "").includes("shell(git push)") || null, "the rules");

    const text = panel.textContent ?? "";
    expect(text).toContain("set by your organisation");
    expect(text).toContain("/etc/troupe/managed.yaml");
    expect(text).toContain("read_file(secrets/**)");
    expect(text).toContain("your config.yaml");
    expect(text).toContain("allow, not applied: a project's file sets it only in a trusted workspace");
    // Shown, not edited: nothing in the panel changes a rule.
    expect(panel.querySelectorAll("button, input, select, textarea").length).toBe(0);
  });

  it("says when there are none", async () => {
    daemon = new FakeDaemon({ osUser: "ada" });
    await daemon.start();
    location.hash = `#daemon=${daemon.port}:${daemon.token}`;
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".me"), "the shell");

    nav("This computer")!.click();
    const panel = await waitFor(() => rulesPanel(), "the rules panel");
    expect(panel.textContent).toContain("No rules");
  });
});

describe("an approval a rule asked for", () => {
  it("names the rule and whose it is", async () => {
    const entry: Extract<Entry, { kind: "approval" }> = {
      kind: "approval",
      seq: 3,
      agent: ["root"],
      callId: "c1",
      tool: "shell",
      args: { command: "git push" },
      decision: undefined,
      resolvedBy: undefined,
      closed: false,
      rule: { rule: "shell(git push)", scope: "enforced", source: "/etc/troupe/managed.yaml" },
    };

    unmount = render(<ApprovalPanel entry={entry} canAnswer others={[]} onAnswer={async () => undefined} />).unmount;
    await waitFor(() => says("Asked by the rule") || null, "the rule");
    expect(says("ask shell(git push)")).toBe(true);
    expect(says("set by your organisation")).toBe(true);
  });
});
