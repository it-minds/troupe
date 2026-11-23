// A session that compacted opens from its latest checkpoint (troupe #1182): the summary of
// what came before as a quote, then the turns after it, and nothing before it until Earlier
// pages it in, a page at a time, drawn above what was on screen without moving it; a line
// that arrives while a page is on its way goes under the tail. A session that never
// compacted opens from its first event, as it did.

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket as NodeWebSocket } from "ws";
import { App } from "../src/App";
import { holdPlace } from "../src/anchor";
import { FakeDaemon } from "../../../packages/client/test/support/daemon.js";
import { SUMMARY, longSession } from "../../../packages/client/test/support/long.js";
import { render, says, startOnTheList, waitFor } from "./support";

Element.prototype.scrollIntoView = function scrollIntoView() {};
globalThis.WebSocket = NodeWebSocket as unknown as typeof WebSocket;

let daemon: FakeDaemon;
let unmount: (() => void) | null = null;

beforeEach(async () => {
  localStorage.clear();
  localStorage.setItem("troupe.pref.localOnly", "yes");
  startOnTheList();
  daemon = new FakeDaemon({ osUser: "ada" });
  await daemon.start();
  location.hash = `#daemon=${daemon.port}:${daemon.token}`;
});

afterEach(async () => {
  unmount?.();
  unmount = null;
  location.hash = "";
  await daemon.stop();
});

const stream = (): HTMLElement => document.querySelector<HTMLElement>(".stream")!;
const earlierButton = (): HTMLButtonElement | null => document.querySelector<HTMLButtonElement>(".earlier-more button");
const people = (): string[] => [...stream().querySelectorAll(".turn.person .body")].map((b) => b.textContent ?? "");

async function open(workspace: string, last: string): Promise<void> {
  unmount = render(<App />).unmount;
  const row = await waitFor(() => [...document.querySelectorAll<HTMLButtonElement>("button.row")].find((b) => b.textContent?.includes(workspace)), "the row");
  row.click();
  await waitFor(() => says(last, stream()), "the last answer");
}

describe("a session that compacted", () => {
  it("opens with the summary and the turns after its checkpoint, and pages back to its start", async () => {
    // Sixty turns of ten events; compacted after the 55th, its checkpoint at the rest after the 56th.
    const session = daemon.seed("/home/ada/compacted");
    longSession(session.log, 60, { compactAt: 55 });
    const checkpoint = session.log.latestCheckpoint()!;
    const through = Number(checkpoint.data["through"]);
    await open("/home/ada/compacted", "answer 59");

    expect(daemon.subscribedFrom.filter((s) => s.sessionId === session.id).map((s) => s.from)).toEqual(["checkpoint"]);
    const summary = stream().querySelector(".earlier")!;
    expect(summary.textContent).toContain("Earlier, summarised");
    expect(summary.querySelector("blockquote")!.textContent).toContain("Each turn read");
    expect(summary.textContent).not.toContain("`lib/`");
    // Only the tail is drawn: the turns after `through`, none from before it.
    expect(people()).toEqual(["turn 56", "turn 57", "turn 58", "turn 59"]);

    earlierButton()!.click();
    await waitFor(() => people().includes("turn 10"), "the first page");
    expect(daemon.pagesAsked).toEqual([through + 1]);
    // In order, above the summary: the five hundred events before the checkpoint's `through`, and not the start.
    const paged = session.log.events.filter((e) => e.type === "user_input" && e.seq > through - 500 && e.seq <= through).map((e) => String(e.data["text"]));
    expect(paged[0]).not.toBe("turn 0");
    expect(people()).toEqual([...paged, "turn 56", "turn 57", "turn 58", "turn 59"]);
    const text = stream().textContent!;
    expect(text.indexOf("answer 55")).toBeLessThan(text.indexOf("Earlier, summarised"));

    earlierButton()!.click();
    await waitFor(() => earlierButton() === null, "the start reached");
    expect(people().slice(0, 7)).toEqual(["turn 0", "turn 1", "turn 2", "turn 3", "turn 4", "turn 5", "turn 6"]);
    expect(daemon.pagesAsked).toHaveLength(2);
    // The summary stays where the checkpoint is, between the history and the tail.
    expect(SUMMARY).toContain("answered with its number");
    const all = stream().textContent!;
    expect(all.indexOf("answer 55")).toBeLessThan(all.indexOf("answered with its number"));
    expect(all.indexOf("answered with its number")).toBeLessThan(all.indexOf("answer 56"));
  });

  it("puts a line that arrives while a page is on its way under the tail, not with the page", async () => {
    const session = daemon.seed("/home/ada/compacted");
    longSession(session.log, 60, { compactAt: 55 });
    await open("/home/ada/compacted", "answer 59");

    daemon.delayMs["session.events"] = 300;
    earlierButton()!.click();
    await waitFor(() => earlierButton()?.disabled, "the page asked for");
    session.log.append("user_input", { source: "user", text: "one more thing" }, { kind: "user", subject: "local:ada" });
    await waitFor(() => people().includes("one more thing"), "the live line");
    await waitFor(() => people().includes("turn 10"), "the page");
    expect(people().at(-1)).toBe("one more thing");
    expect(people().at(-2)).toBe("turn 59");
  });
});

describe("a session that never compacted", () => {
  it("opens from its first event as before, with no summary and nothing earlier to read", async () => {
    const session = daemon.seed("/home/ada/short");
    longSession(session.log, 5);
    await open("/home/ada/short", "answer 4");
    expect(people()).toEqual(["turn 0", "turn 1", "turn 2", "turn 3", "turn 4"]);
    expect(stream().querySelector(".earlier")).toBeNull();
    expect(earlierButton()).toBeNull();
    expect(daemon.pagesAsked).toEqual([]);
  });
});

describe("the reader's place", () => {
  // jsdom lays nothing out, so where each child is is said here: the container at 100, the
  // children 50 high from where the content starts, which a page drawn above moves down.
  function laidOut(container: HTMLElement, above: () => number): void {
    container.getBoundingClientRect = () => ({ top: 100, bottom: 600 }) as DOMRect;
    [...container.children].forEach((c, i) => {
      (c as HTMLElement).getBoundingClientRect = () => {
        const top = 100 - container.scrollTop + above() + i * 50;
        return { top, bottom: top + 50 } as DOMRect;
      };
    });
  }

  it("keeps the first entry on screen where it was when a page is drawn above it", () => {
    const container = document.createElement("div");
    container.innerHTML = `<p class="earlier-more">Earlier</p><section>a</section><section>b</section><section>c</section>`;
    document.body.append(container);
    let above = 0;
    laidOut(container, () => above);
    container.scrollTop = 30;
    const restore = holdPlace(container);
    const before = container.children[1]!.getBoundingClientRect().top;
    above = 1200; // a page of history drawn above
    restore();
    expect(container.children[1]!.getBoundingClientRect().top).toBe(before);
    expect(container.scrollTop).toBe(1230);
    container.remove();
  });
});
