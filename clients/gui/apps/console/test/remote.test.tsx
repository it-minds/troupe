// Laptop sessions offered to you, steered from the console (troupe #58): listed under Mine on Sessions,
// opened as yourself, the transcript followed live, a prompt sent and an approval answered
// once; a laptop that is away is said to be, with since when. A member who administers
// nothing does all of it, and is shown nothing that was not offered to them. The list is
// the plane's watch: an offer made, withdrawn or gone offline shows as it happens, with no
// `remote.list` asked again. The fake plane's worker stands in for the laptop.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { App } from "../src/App";
import { statusWords } from "../src/views/Remote";
import { emptyTranscript } from "@troupe/client";
import { NodeWebSocket } from "../../../packages/client/test/support/ws.js";
import { PEOPLE, button, freshBrowser, render, sees, signedInAs, startFake, visit, waitFor } from "./support";
import type { FakeDeployment } from "./support";

globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let fake: FakeDeployment;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  freshBrowser();
  fake = await startFake();
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  await fake.stop();
});

function typed(field: HTMLTextAreaElement, value: string): void {
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, value);
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

const offered = (id: string) => [...document.querySelectorAll<HTMLAnchorElement>(".remote-sessions a")].find((a) => a.textContent === id);

/** How long an offer may take to show: the push's, nowhere near a poll's. */
const PUSHED_MS = 1_000;

describe("laptop sessions offered to you", () => {
  it("are listed under Mine on Sessions, opened as yourself, followed, prompted and answered", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-1", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/mine");
    unmount = render(<App />).unmount;

    await sees("Offered to you from laptops");
    const link = await waitFor(() => offered("s-laptop-1"), "the offered session");
    await sees("Ada", () => link.closest("tr"));
    link.click();

    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");
    const prompt = await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt");
    typed(prompt, "approve: rm -rf build");
    button("Send")!.click();

    await sees("approve: rm -rf build", () => document.querySelector('[aria-label="Transcript"]'));
    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    button("Allow once", approval)!.click();

    const decided = await waitFor(() => fake.worker.calls.find((c) => c.method === "approval.respond"), "the answer at the laptop");
    expect(decided.params["decision"]).toBe("allow");
  });

  it("say the laptop is offline, and since when, when it is away", async () => {
    const away = fake.plane.relay("ada@example.com", { id: "s-laptop-2", ownerName: "Ada", workspace: "drafts", shares: [{ subject: PEOPLE.alice.subject, role: "observe" }] });
    fake.plane.offline(away.id, new Date().toISOString());
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/remote/s-laptop-2");
    unmount = render(<App />).unmount;

    await sees("The laptop is offline since");
  });

  // The stream's own events name who said what by name where the actor carries one, so
  // somebody present nowhere else on the page is still a name, not an email (troupe #931).
  it("names each person in the transcript as the event's actor names them, the subject where it names nobody", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-6", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.alice.subject, role: "observe" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/sessions/remote/s-laptop-6");
    unmount = render(<App />).unmount;
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");

    const log = fake.worker.sessions.get("s-laptop-6")!.log;
    log.append("user_input", { source: "user", text: "from Bea" }, { kind: "user", subject: "idp|bea", display_name: "Bea Example" });
    log.append("user_input", { source: "user", text: "from Cy" }, { kind: "user", subject: "cy@example.com" });

    await sees("Bea Example: from Bea", () => document.querySelector('[aria-label="Transcript"]'));
    await sees("cy@example.com: from Cy", () => document.querySelector('[aria-label="Transcript"]'));
  });

  it("a link kept from the Mine page opens the session where it is now, and the address becomes its own", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-3", ownerName: "Ada", shares: [{ subject: PEOPLE.alice.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.alice);
    visit("#/mine/remote/s-laptop-3");
    unmount = render(<App />).unmount;

    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");
    await waitFor(() => globalThis.location.hash === "#/sessions/remote/s-laptop-3", "the address rewritten");
    expect(document.querySelector(".banner.refused")).toBeNull();
  });
});

describe("a member who administers nothing", () => {
  it("steers a session offered to them from the console, as themselves", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-4", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.carol.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.carol);
    unmount = render(<App />).unmount;

    (await waitFor(() => offered("s-laptop-4"), "the offered session on Mine")).click();
    await waitFor(() => document.querySelector('[role="status"]')?.textContent?.startsWith("Idle"), "the session attached");
    typed(await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt"), "hello from the train");
    button("Send")!.click();

    const sent = await waitFor(() => fake.worker.calls.find((c) => c.method === "input.send"), "the prompt at the laptop");
    expect(sent.params["text"]).toBe("hello from the train");
    await sees("You: hello from the train", () => document.querySelector('[aria-label="Transcript"]'));
  });

  it("is shown nothing that was not offered to them, and cannot open it by its address", async () => {
    fake.plane.relay("ada@example.com", { id: "s-laptop-5", ownerName: "Ada", shares: [{ subject: PEOPLE.bob.subject, role: "control" }] });
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions/mine");
    unmount = render(<App />).unmount;
    await sees("Nothing offered to you");
    expect(offered("s-laptop-5")).toBeUndefined();

    unmount();
    visit("#/sessions/remote/s-laptop-5");
    unmount = render(<App />).unmount;
    await sees("It is no longer offered to you");
    expect(fake.worker.calls.some((c) => c.method === "subscribe" && c.params["topic"] === "session:s-laptop-5")).toBe(false);
  });
});

describe("the list follows the plane as it changes", () => {
  it("an offer made on a laptop shows within a second, from the plane's push and not a poll; its laptop going and its withdrawal too", async () => {
    await signedInAs(fake, PEOPLE.carol);
    visit("#/sessions/mine");
    unmount = render(<App />).unmount;
    await sees("Nothing offered to you");
    await waitFor(() => fake.plane.watches.size === 1, "the console's watch, its initialize answered");
    // A push from here on is behind that answer on the socket, and is heard even when both
    // arrive in one read.
    const asked = fake.plane.asked.filter((m) => m === "remote.list").length;

    const at = Date.now();
    fake.plane.relay("ada@example.com", { id: "s-laptop-6", ownerName: "Ada", workspace: "billing", shares: [{ subject: PEOPLE.carol.subject, role: "observe" }] });
    const link = await waitFor(() => offered("s-laptop-6"), "the offer, pushed", PUSHED_MS);
    expect(Date.now() - at).toBeLessThan(PUSHED_MS);
    await sees("online", () => link.closest("tr"));

    fake.plane.offline("s-laptop-6");
    await waitFor(() => offered("s-laptop-6")?.closest("tr")?.textContent?.includes("offline since"), "the laptop gone, pushed", PUSHED_MS);

    fake.plane.withdraw("s-laptop-6");
    await waitFor(() => !offered("s-laptop-6"), "the withdrawal, pushed", PUSHED_MS);

    expect(fake.plane.asked.filter((m) => m === "remote.list").length, "the list was asked again rather than told").toBe(asked);
  });
});

/** The session's status line, as a person reads it. */
const statusLine = (): string => document.querySelector(".remote-session [role=\"status\"]")?.textContent ?? "";
const transcript = (): Element | null => document.querySelector('[aria-label="Transcript"]');

async function opened(fake: FakeDeployment, id: string, role: "observe" | "control", who = PEOPLE.carol): Promise<void> {
  fake.plane.relay("ada@example.com", { id, ownerName: "Ada", workspace: "billing", shares: [{ subject: who.subject, role }] });
  await signedInAs(fake, who);
  visit(`#/sessions/remote/${id}`);
  unmount = render(<App />).unmount;
  await waitFor(() => statusLine().startsWith("Idle"), "the session attached");
}

describe("a session offered to follow (troupe #899)", () => {
  it("draws no prompt box, no agent and no Send, and says what the grant allows", async () => {
    await opened(fake, "s-follow-1", "observe");
    await sees("You follow this session; its owner can let you steer it.");
    expect(document.querySelector(".composer")).toBeNull();
    expect(document.querySelector(".remote-session textarea")).toBeNull();
    expect(document.querySelector(".remote-session select")).toBeNull();
    expect(button("Send")).toBeNull();
  });

  it("a refusal keeps the typed prompt and says why in words, never the method and its code", async () => {
    await opened(fake, "s-refuse-1", "control");
    fake.worker.refusing.set("input.send", { code: -32004, message: "forbidden", data: { required_scope: "control" } });
    const prompt = await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt");
    typed(prompt, "tidy the ledger");
    button("Send")!.click();

    const alert = await waitFor(() => document.querySelector<HTMLElement>('.remote-session [role="alert"]'), "the refusal");
    expect(alert.textContent).toBe("You follow this session and cannot steer it: its owner can let you.");
    expect(document.querySelector<HTMLTextAreaElement>(".composer textarea")!.value).toBe("tidy the ledger");

    // A refusal that says nothing more is still said in words.
    fake.worker.refusing.set("input.send", { code: -32004, message: "forbidden" });
    button("Send")!.click();
    await waitFor(() => document.querySelector('.remote-session [role="alert"]')?.textContent === "The session refused that.", "the bare refusal");
    expect(document.body.textContent).not.toContain("-32004");
    expect(document.querySelector<HTMLTextAreaElement>(".composer textarea")!.value).toBe("tidy the ledger");
  });
});

describe("a relayed approval (troupe #899)", () => {
  it("shows the command, its folder and what allowing it does, says it is waiting for you, and records the answer", async () => {
    await opened(fake, "s-approve-1", "control");
    await sees("Nothing yet: the session has not said anything.");
    typed(await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt"), "approve: ls -la");
    button("Send")!.click();

    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    await waitFor(() => statusLine().startsWith("Waiting for you"), "the status waiting for you");
    expect(approval.textContent).toContain("Run a command?");
    expect(approval.querySelector(".command")?.textContent).toBe("ls -la");
    // The folder the laptop said the call acts in, not the offer's name for it (troupe #932).
    expect(approval.textContent).toContain("In /workspace.");
    expect(approval.textContent).toContain("It runs on the laptop the session is on");
    // The laptop takes an answer for the session from here, in the desktop app's words.
    expect(approval.textContent).not.toContain("allowing it for the rest of the session is done at the laptop");
    await waitFor(() => button("Allow once", approval), "allow once");
    await waitFor(() => button("Deny", approval), "deny");

    button("Allow every command for this session", approval)!.click();
    const decided = await waitFor(() => fake.worker.calls.find((c) => c.method === "approval.respond"), "the answer at the laptop");
    expect(decided.params["decision"]).toBe("allow_session");
    await sees("Allowed for this session by you: run a command · ls -la", transcript);
    await sees("✓ shell ls -la", transcript);
    await waitFor(() => statusLine().startsWith("Idle"), "idle again");
    expect(document.querySelector('[aria-label="Approve shell"]')).toBeNull();
  });

  it("on a laptop from before, answers once, says why, and names the offer's folder", async () => {
    fake.worker.relayedAllowSession = false;
    await opened(fake, "s-approve-2", "control");
    await sees("Nothing yet: the session has not said anything.");
    // A daemon from before says no folder of the call's own.
    fake.worker.sessions.get("s-approve-2")!.log.append("approval_requested", { call_id: "call-old", tool: "shell", args: { command: "ls" }, agent_path: ["root"] });

    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    expect(approval.textContent).toContain("In billing.");
    expect(approval.textContent).toContain("allowing it for the rest of the session is done at the laptop");
    expect(button("Allow every", approval)).toBeNull();
    await waitFor(() => button("Allow once", approval), "allow once");
  });

  it("a question's options are buttons, and its answer stays as a line", async () => {
    await opened(fake, "s-ask-1", "control");
    typed(await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt"), "ask: Which branch? | main | develop");
    button("Send")!.click();

    const asked = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="The agent asks"]'), "the question");
    await waitFor(() => statusLine().startsWith("Waiting for you"), "the status waiting for you");
    expect(asked.textContent).toContain("Which branch?");
    button("develop", asked)!.click();

    const answered = await waitFor(() => fake.worker.calls.find((c) => c.method === "question.answer"), "the answer at the laptop");
    expect(answered.params["text"]).toBe("develop");
    await sees("Asked: Which branch? · answered: develop", transcript);
  });

  it("a follower sees the approval and is offered no answer", async () => {
    await opened(fake, "s-follow-2", "observe");
    // Somebody who steers it asks for a command; the follower reads it.
    const session = fake.worker.sessions.get("s-follow-2")!;
    session.log.append("approval_requested", { call_id: "call-x", tool: "shell", args: { command: "make test" }, agent_path: ["root"] });
    const approval = await waitFor(() => document.querySelector<HTMLElement>('[aria-label="Approve shell"]'), "the approval");
    expect(approval.querySelector(".command")?.textContent).toBe("make test");
    expect(approval.querySelector("button")).toBeNull();
    await waitFor(() => statusLine().startsWith("Waiting for an answer"), "the status waiting");
  });
});

describe("the page's head (troupe #899)", () => {
  it("names Sessions as the way back, to its Mine, and the page repeats no crumb", async () => {
    await opened(fake, "s-head-1", "control");
    const crumb = document.querySelector(".head .crumb")!;
    expect(crumb.textContent).toBe("Watch / Sessions");
    expect(crumb.querySelector("a")?.getAttribute("href")).toBe("#/sessions/mine");
    expect(document.body.textContent).not.toContain("← Sessions");
    await sees("on Ada's laptop, through the plane");
  });
});

describe("the status line, in words", () => {
  it("says the laptop was lost, with the reason, while it tries again", () => {
    expect(statusWords("reconnecting", "the socket closed; attempt 2", emptyTranscript, { steer: true, laptop: true })).toBe("Lost the laptop: the socket closed; attempt 2. Trying again");
    expect(statusWords("failed", "the laptop is offline", emptyTranscript, { steer: true, laptop: true })).toBe("Lost the laptop: the laptop is offline");
    expect(statusWords("connecting", null, emptyTranscript, { steer: true, laptop: true })).toBe("Connecting");
    expect(statusWords("live", null, emptyTranscript, { steer: true, laptop: true })).toBe("Idle");
  });

  it("says the laptop is away from the plane's word, and that it is back (troupe #932)", () => {
    const asleep = { ...emptyTranscript, laptop: { state: "away" as const, reason: "offline", since: undefined } };
    const stopped = { ...emptyTranscript, laptop: { state: "away" as const, reason: "stopped", since: undefined } };
    const back = { ...emptyTranscript, laptop: { state: "back" as const } };
    expect(statusWords("live", null, asleep, { steer: true, laptop: true })).toBe("The laptop is asleep or offline; waiting for it");
    expect(statusWords("live", null, stopped, { steer: true, laptop: true })).toBe("Troupe stopped on the laptop; waiting for it to start again");
    expect(statusWords("reconnecting", "the laptop is back; attempt 1", back, { steer: true, laptop: true })).toBe("The laptop is back");
    expect(statusWords("live", null, back, { steer: true, laptop: true })).toBe("The laptop is back · Idle");
    // This page's own connection lost while the laptop is away keeps the attachment's words.
    expect(statusWords("reconnecting", "socket error; attempt 1", asleep, { steer: true, laptop: true })).toBe("Lost the laptop: socket error; attempt 1. Trying again");
  });
});

describe("a laptop that goes away and comes back (troupe #932)", () => {
  it("is waited for in words, refuses a prompt meanwhile in words, and is followed again once back", async () => {
    await opened(fake, "s-away-1", "control");

    fake.plane.pause("s-away-1", "offline");
    await waitFor(() => statusLine().startsWith("The laptop is asleep or offline; waiting for it"), "the status waiting for the laptop");

    // A prompt sent meanwhile is refused in the plane's words and stays in the box.
    const prompt = await waitFor(() => document.querySelector<HTMLTextAreaElement>(".composer textarea"), "the prompt");
    typed(prompt, "are you there?");
    button("Send")!.click();
    await sees("The laptop is away: nothing sent now reaches it. Send it again once the laptop is back.");
    expect(prompt.value).toBe("are you there?");

    fake.plane.resume("s-away-1");
    await waitFor(() => statusLine().startsWith("The laptop is back"), "the status saying it is back");
    // Opened again from its cursor, it is steered as before.
    await waitFor(() => statusLine().startsWith("The laptop is back · Idle"), "attached again");
    button("Send")!.click();
    await sees("You said: are you there?", transcript);
    await waitFor(() => statusLine().startsWith("Idle"), "the status in its own words once the session spoke");
  });
});