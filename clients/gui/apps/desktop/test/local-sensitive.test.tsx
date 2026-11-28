// troupe #1239, on this computer: This computer's settings show a sensitive session's rules
// in effect, the organisation's enforced file's and the person's own config.yaml's, each with
// where it came from and none of it edited here; and a session here is marked sensitive by
// hand from the ⋯ through its daemon, where the daemon says it marks sessions, and not where
// it does not. The app rendered, the fake daemon on a real socket.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { button, nav, render, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon | null = null;
let unmount: (() => void) | null = null;

const CAPABILITIES = { blobs: true, tools: true, approval_allow_always: true, fs_upload_artifact: true, checkpoints: true, lifespans: true };

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

async function started(sensitive: boolean): Promise<FakeDaemon> {
  daemon = new FakeDaemon({ osUser: "ada", capabilities: { ...CAPABILITIES, sensitive } });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
  return daemon;
}

const entry = (title: string): HTMLLIElement | undefined =>
  [...document.querySelectorAll<HTMLLIElement>("ul.rows > li")].find((li) => li.querySelector(".title")?.textContent === title);
const headTag = (): HTMLElement | null => document.querySelector<HTMLElement>(".session-head .crumbs .tag.sensitive");
const confirm = (): HTMLElement | null => document.querySelector<HTMLElement>('[role="alertdialog"][aria-label="Make it sensitive"]');

async function menu(): Promise<HTMLElement> {
  (await waitFor(() => document.querySelector<HTMLButtonElement>('button[aria-label="More session actions"]'), "the ⋯")).click();
  return waitFor(() => {
    const pop = document.querySelector<HTMLElement>(".session-menu .menu-pop");
    return pop && !pop.hidden && pop;
  }, "the ⋯ menu");
}

async function openSession(title: string): Promise<void> {
  unmount = render(<App />).unmount;
  (await waitFor(() => entry(title)?.querySelector<HTMLButtonElement>("button.row"), `the row for ${title}`)).click();
  await waitFor(() => document.querySelector<HTMLElement>(".session-head"), "the session");
}

describe("This computer's sensitive sessions", () => {
  it("lists the rules in effect with where each came from, the organisation's and yours, none of it edited here", async () => {
    const d = await started(true);
    const managed = "/etc/troupe/managed.yaml";
    const mine = "/home/ada/.config/troupe/config.yaml";
    const rule = (text: string, scope: string, source: string) => ({ action: "deny", rule: text, tool: text.split("(")[0], pattern: null, scope, source, ignored: null });
    d.sensitiveRules = {
      marked_by: [rule("mcp(records.*)", "enforced", managed), rule("read_file(/srv/hr/**)", "user", mine)],
      deny: [rule("publish_artifact", "enforced", managed)],
      sharing: { value: "ask", scope: "enforced", source: managed },
    };
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".me"), "the shell");

    nav("This computer")!.click();
    const panel = await waitFor(() => document.querySelector<HTMLElement>('section[aria-label="Sensitive sessions"]'), "the sensitive panel");
    const text = panel.textContent ?? "";
    expect(text).toContain("mcp(records.*)");
    expect(text).toContain("marks it sensitive");
    expect(text).toContain("set by your organisation");
    expect(text).toContain(managed);
    expect(text).toContain("read_file(/srv/hr/**)");
    expect(text).toContain("your config.yaml");
    expect(text).toContain("refused once sensitive");
    expect(text).toContain("refused here: no team administrator answers a request from this computer");
    expect(panel.querySelectorAll("button, input, select, textarea").length).toBe(0);
  });

  it("is not drawn where nothing sets them", async () => {
    await started(true);
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector(".me"), "the shell");
    nav("This computer")!.click();
    await waitFor(() => document.querySelector('section[aria-label="Permission rules"]'), "the rules panel");
    expect(document.querySelector('section[aria-label="Sensitive sessions"]')).toBeNull();
  });
});

describe("making a session on this computer sensitive", () => {
  it("is offered from the ⋯ where the daemon marks sessions, asked once more, then marked and the item gone", async () => {
    const d = await started(true);
    const ward = d.seed("/w/ward", { title: "Ward 7" });
    await openSession("Ward 7");
    let pop = await menu();
    (await waitFor(() => button("Make it sensitive", pop), "the ⋯'s item")).click();
    const sheet = await waitFor(confirm, "the confirm sheet");
    // Whose rules hold it here: this computer's, never a profile it does not have.
    expect(sheet.textContent).toContain("the rules this computer runs under refuse");
    expect(sheet.textContent).not.toContain("profile");
    button("Make it sensitive", sheet)!.click();
    await waitFor(() => ward.sensitive?.["how"] === "person" || null, "the daemon told");
    await waitFor(() => headTag()?.textContent === "sensitive" || null, "the head's tag");
    const banner = await waitFor(() => document.querySelector<HTMLElement>(".banner.sensitive"), "the line under the head");
    expect(banner.textContent).toContain("the rules this computer runs under refuse");
    expect(banner.textContent).not.toContain("profile");
    const line = await waitFor(() => document.querySelector<HTMLElement>(".note.sensitive"), "the transcript's line");
    expect(line.textContent).toContain("the rules this computer runs under refuse");
    expect(line.textContent).not.toContain("profile");
    pop = await menu();
    await waitFor(() => button("Keep at the top", pop), "the ⋯'s items");
    expect(button("Make it sensitive", pop)).toBeNull();
  });

  it("is not offered where the daemon does not mark sessions", async () => {
    const d = await started(false);
    d.seed("/w/ward", { title: "Ward 7" });
    await openSession("Ward 7");
    const pop = await menu();
    await waitFor(() => button("Keep at the top", pop), "the ⋯'s items");
    expect(button("Make it sensitive", pop)).toBeNull();
  });
});
